// 美肌用の Core Image カーネル（Metal）。ビルド設定で -fcikernel / -cikernel を付けてコンパイルする。
#include <CoreImage/CoreImage.h>

extern "C" {
namespace coreimage {

/// バイラテラルフィルタ。周りの画素のうち「近くにあって、しかも色が近いもの」だけを平均する。
/// 肌のむらや毛穴はならされるが、メガネのフチ・眉・目のように色が大きく違う境目は混ざらずに残る。
/// 重みで割って平均するので、全体の明るさや色は変わらない。
/// radius: ならす範囲（ピクセル）、sigmaColor: 「色が近い」とみなす差（0〜1）
float4 bilateral(sampler src, float radius, float sigmaColor, destination dest) {
    float2 coord = dest.coord();
    float4 center = src.sample(src.transform(coord));
    float4 sum = float4(0.0);
    float weightSum = 0.0;
    float step = radius / 4.0;
    float spatialDenominator = 2.0 * (radius * 0.6) * (radius * 0.6);
    float colorDenominator = 2.0 * sigmaColor * sigmaColor;
    for (int y = -4; y <= 4; y++) {
        for (int x = -4; x <= 4; x++) {
            float2 offset = float2(float(x), float(y)) * step;
            float4 color = src.sample(src.transform(coord + offset));
            float3 difference = color.rgb - center.rgb;
            float weight = exp(-dot(offset, offset) / spatialDenominator)
                         * exp(-dot(difference, difference) / colorDenominator);
            sum += color * weight;
            weightSum += weight;
        }
    }
    return sum / weightSum;
}

/// 周りより「少しだけ」暗い部分（シミ・シワ）を、周りの平均の色で埋める。
/// mean: 元の画像をぼかしたもの（周りの平均）。暗さの差が low〜high の間で効き始め、high 以上で最大になる。
/// 差が cap を超えるほど暗い所（メガネのフチ・髪・指の間のかげ）はシミではないので変えない。
/// 明るい部分（ハイライト）や、周りと同じ明るさの所も変えない。
/// local: src をごく少しだけぼかしたもの。暗さの判定はこれで行い、画素ごとのばらつきで
/// 「消す画素」と「残す画素」が交互になって点線のようなむらが出るのを防ぐ。
/// darkest: 近くの画素のうちいちばん暗い値。近くにメガネのフチ・髪のような真っ黒なものがあれば、
/// その周りは細い所も含めて一切変えない（cap による判定。範囲で決まるので点々にもならない）。
float4 darkSpotRemoval(sampler src, sampler local, sampler darkest, sampler mean,
                       float strength, float low, float high, float cap, destination dest) {
    float2 coord = dest.coord();
    float4 color = src.sample(src.transform(coord));
    float4 nearby = local.sample(local.transform(coord));
    float4 darkestNearby = darkest.sample(darkest.transform(coord));
    float4 average = mean.sample(mean.transform(coord));
    float3 lumaWeights = float3(0.299, 0.587, 0.114);
    float averageLuma = dot(average.rgb, lumaWeights);
    float darker = averageLuma - dot(nearby.rgb, lumaWeights);
    float darkestGap = averageLuma - dot(darkestNearby.rgb, lumaWeights);
    float weight = smoothstep(low, high, darker) * (1.0 - smoothstep(cap * 0.5, cap, darkestGap)) * strength;
    return float4(mix(color.rgb, average.rgb, weight), color.a);
}

/// 赤み消し。周りの肌より赤い所（ニキビ・小鼻の際・眉の際の赤み）だけを、周りの肌の色になじませる。
/// 赤い色を一律に薄くする（彩度を下げる）のではないので、顔全体の血色は変わらない。
/// skinSum: 肌だけを残した画像をぼかしたもの、skinWeight: 肌のマスクを同じだけぼかしたもの。
/// skinSum / skinWeight が「周りの肌だけの平均の色」になる（髪・背景・唇の色は混ざらない）。
/// 赤い所は少し暗いことが多いので、周りより暗いぶんも一緒に戻す。
float4 rednessRemoval(sampler src, sampler skinSum, sampler skinWeight, float strength, destination dest) {
    float2 coord = dest.coord();
    float4 color = src.sample(src.transform(coord));
    float4 sum = skinSum.sample(skinSum.transform(coord));
    float weightSum = skinWeight.sample(skinWeight.transform(coord)).r;
    if (weightSum < 0.02) {
        return color;
    }
    float3 average = sum.rgb / weightSum;
    float3 lumaWeights = float3(0.299, 0.587, 0.114);

    // 明るさと色み（赤み = R - Y、青み = B - Y）に分ける
    float y = dot(color.rgb, lumaWeights);
    float cr = color.r - y;
    float cb = color.b - y;
    float averageY = dot(average, lumaWeights);
    float averageCr = average.r - averageY;
    float averageCb = average.b - averageY;

    // 周りより赤い（赤みが多く、青みが少ない）ほど強く効かせる。周りと同じか赤くない所は変えない
    float excess = (cr - averageCr) - 0.5 * (cb - averageCb);
    // 周りよりずっと暗い所（メガネのフチ・髪・ほくろ）は赤みがあってもニキビではないので変えない
    float darkGuard = 1.0 - smoothstep(0.12, 0.25, averageY - y);
    float weight = smoothstep(0.004, 0.04, excess) * darkGuard * strength;

    float newCr = mix(cr, averageCr, weight);
    float newCb = mix(cb, averageCb, weight);
    float newY = y + max(0.0, averageY - y) * weight * 0.6;

    float r = newY + newCr;
    float b = newY + newCb;
    float g = (newY - 0.299 * r - 0.114 * b) / 0.587;
    return float4(clamp(float3(r, g, b), 0.0, 1.0), color.a);
}

/// ダイレクトフラッシュ。Core Image の作業色空間はリニア（光の量に比例）なので、明るさをそのまま比べられる。
/// photoLow: フラッシュ写真をぼかしたもの、ambientLow: 発光直前のコマ（周りの光だけ）をぼかしたもの。
/// ratio: コマの明るさを写真の露出にそろえる倍率。ambientGain: 周りの光を何倍にするか（0.25 で 2 段暗く）。
/// 写真の明るさのうち周りの光の割合 f を求め、明るさを (1 - f) + f * ambientGain 倍にする
/// ＝フラッシュの光はそのまま、周りの光だけを減らす。
float4 directFlash(sampler photo, sampler photoLow, sampler ambientLow, float ratio, float ambientGain,
                   destination dest) {
    float2 coord = dest.coord();
    float4 color = photo.sample(photo.transform(coord));
    float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    float total = dot(photoLow.sample(photoLow.transform(coord)).rgb, lumaWeights);
    float ambient = dot(ambientLow.sample(ambientLow.transform(coord)).rgb, lumaWeights) * ratio;
    float f = clamp(ambient / max(total, 0.0005), 0.0, 1.0);
    float gain = (1.0 - f) + f * ambientGain;
    return float4(color.rgb * gain, color.a);
}

/// 青ひげ隠し。ひげの剃り跡は、皮膚の下の毛が透けて「周りの肌より青く・少し暗く」見える。
/// メイクの色補正（青の反対色のオレンジで打ち消す）と同じ考えで、周りの肌の色との差のうち
/// 青み・暗さの分だけを打ち消す。細かい質感（src - local）は残すので、塗りつぶしたようにはならない。
/// skinSum / skinWeight: ひげの所を除いた肌の平均の色（頬などから広くぼかして求める）。
/// local: src を少しぼかしたもの（剃り跡のむらを判定する）。
/// 周りよりずっと暗い所（伸びたひげ・鼻の穴・影）は剃り跡ではないので変えない。
/// debug が 1 のときは、確認用に (効き具合 w, 参照できる肌の量 ×10, 青み, 暗さ ×10) を色として返す。
float4 beardConceal(sampler src, sampler local, sampler skinSum, sampler skinWeight, float strength,
                    float debug, destination dest) {
    float2 coord = dest.coord();
    float4 color = src.sample(src.transform(coord));
    float weightSum = skinWeight.sample(skinWeight.transform(coord)).r;
    if (weightSum < 0.0005) {
        return debug > 0.5 ? float4(0.0, weightSum * 10.0, 0.0, 1.0) : color;
    }
    float3 average = skinSum.sample(skinSum.transform(coord)).rgb / weightSum;
    float3 near = local.sample(local.transform(coord)).rgb;
    float3 lumaWeights = float3(0.299, 0.587, 0.114);

    float nearY = dot(near, lumaWeights);
    float averageY = dot(average, lumaWeights);
    float nearCb = near.b - nearY, nearCr = near.r - nearY;
    float averageCb = average.b - averageY, averageCr = average.r - averageY;

    // 比べる肌の色みは、その場所の暗さにそろえる（リニアの色空間では、同じ肌でも暗い所ほど色みの差も小さい）。
    // そろえないと、影や髪（もみあげ）のような暗い所を明るい肌の色みへ寄せてしまい、赤茶色の斑点になっていた
    float ratioY = nearY / max(averageY, 0.001);
    // 剃り跡の少しの暗さ（リニアで半分以上の明るさ）はそのまま肌の色みを目標にし、それより暗い影・髪だけ弱める
    float shade = clamp(ratioY / 0.5, 0.0, 1.0);
    averageCb *= shade;
    averageCr *= shade;
    // 青い（Cb が高い・Cr が低い）ほど、暗いほど強く効かせる
    float bluish = (nearCb - averageCb) + 0.5 * (averageCr - nearCr);
    float darker = averageY - nearY;
    // Core Image の作業色空間はリニアで、肌の色の差は画面の値より小さく出るので、小さい差から効かせる
    float amount = smoothstep(0.0, 0.012, bluish + 0.5 * max(darker, 0.0));
    // 伸びたひげ・鼻の穴・濃い影は、目標の肌の半分以下の明るさなので変えない。
    // 頬・額より口元が少し暗いのは自然な陰影なので、比で判定する（差で判定すると口元全体が外れていた）
    // 比はリニアの値なので、0.35 は画面の値では 6 割ほどの明るさにあたる。以前はこれより暗い所を外していたため、
    // 影になる口ひげ・下唇の真下・あご下の剃り跡が消えなかった。今は画面の値で 4 割ほど（リニアで 0.15）まで効かせる
    float darkGuard = smoothstep(0.08, 0.15, ratioY);
    float w = amount * darkGuard * strength;
    if (debug > 0.5) {
        return float4(w, weightSum * 10.0, clamp(bluish * 10.0, 0.0, 1.0), 1.0);
    }

    float y = dot(color.rgb, lumaWeights);
    float cb = color.b - y;
    float cr = color.r - y;
    // その画素自身が暗い（髪の毛・もみあげ）ときは変えない。ぼかした明るさだけで判定すると、
    // 肌との境目の髪が肌の色へ寄せられて赤茶色になっていた。
    // 色みを動かす量も、その画素の明るさに比例させる（暗い画素に明るい肌と同じ量を足すと色が浮く）
    float own = clamp(y / max(nearY, 0.001), 0.0, 1.0);
    w *= smoothstep(0.08, 0.15, y / max(averageY, 0.001));
    // 色み（青み）は周りの肌の色へ
    float newCb = cb + (averageCb - nearCb) * w * own;
    float newCr = cr + (averageCr - nearCr) * w * own;
    // 明るさは暗い分の 4 割だけ戻す（戻しすぎると、あごの周りだけ明るく浮いて見える）
    // 影の所（あご下・口元）は明るさを戻すと平たく浮いて見えるので、色みだけを直す
    float lift = 0.4 * smoothstep(0.35, 0.55, ratioY);
    float newY = y + max(0.0, darker) * lift * w;
    float r = newY + newCr;
    float b = newY + newCb;
    float g = (newY - 0.299 * r - 0.114 * b) / 0.587;
    return float4(clamp(float3(r, g, b), 0.0, 1.0), color.a);
}

/// 脚長。出力の各行が、元の画像のどの行から来るかを区分ごとの一次式で決めて、1 回で引き伸ばす
/// （画像を切り分けて継ぎ合わせると、継ぎ目に線が出る・大きな写真で一部が描けないことがあったため）。
/// 座標は上端 0 の行（ピクセル）。h: 画像の高さ、s: 肩、a: 伸ばし始め、b: 伸ばし終わり、
/// u: 肩より上をそのまま上へずらす量、d: 伸ばして増える長さ（d - u は肩〜伸ばし始めで縮める量）
float4 legStretch(sampler src, float h, float s, float a, float b, float u, float d, destination dest) {
    float2 p = dest.coord();
    float y = h - p.y;
    float torso = a - s;
    float squeezed = max(torso - (d - u), 1.0);
    float source;
    if (y < s - u) {
        source = y + u;
    } else if (y < a - d) {
        source = s + (y - (s - u)) * torso / squeezed;
    } else if (y < b) {
        source = a + (y - (a - d)) * (b - a) / (b - a + d);
    } else {
        source = y;
    }
    return src.sample(src.transform(float2(p.x, h - source)));
}

}
}
