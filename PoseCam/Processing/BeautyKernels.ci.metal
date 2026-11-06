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

/// 赤み消し。周りの肌より赤い所（ニキビ・ニキビ跡・小鼻の際・眉の際の赤み）だけを、周りの肌の色になじませる。
/// 赤い色を一律に薄くする（彩度を下げる）のではないので、顔全体の血色は変わらない。
/// skinSum: 肌だけを残した画像をぼかしたもの、skinWeight: 肌のマスクを同じだけぼかしたもの。
/// skinSum / skinWeight が「周りの肌だけの平均の色」になる（髪・背景・唇の色は混ざらない）。
/// 赤みは明るさで割った値（光の強さが変わっても同じ色なら同じ値）で比べる。ニキビ跡は周りより暗いので、
/// 以前のように赤みの量をそのまま比べると、色はずっと赤いのに「周りと同じくらい」と判定されてほとんど効かなかった
/// （実際の写真で、そのままの差は -0.02〜+0.07、明るさで割ると +0.31〜+0.37）。
/// 赤い所は暗いことが多いので、周りより暗いぶんも一緒に戻す。
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

    float y = max(dot(color.rgb, lumaWeights), 0.001);
    float averageY = max(dot(average, lumaWeights), 0.001);
    // 明るさで割った赤み（R - Y）・青み（B - Y）
    float2 c = float2(color.r - y, color.b - y) / y;
    float2 averageC = float2(average.r - averageY, average.b - averageY) / averageY;

    // 周りより赤い（赤みが多く、青みが少ない）ほど強く効かせる。周りと同じか赤くない所は変えない
    float excess = (c.x - averageC.x) - 0.5 * (c.y - averageC.y);
    // 周りよりずっと暗い所（メガネのフチ・髪・ほくろ・まつ毛）は赤みがあってもニキビではないので変えない
    float ratio = y / averageY;
    float darkGuard = smoothstep(0.3, 0.5, ratio);
    float weight = smoothstep(0.04, 0.2, excess) * darkGuard * strength;

    float newY = y + max(0.0, averageY - y) * weight * 0.8;
    float2 newC = mix(c, averageC, weight) * newY;
    float r = newY + newC.x;
    float b = newY + newC.y;
    float g = (newY - 0.299 * r - 0.114 * b) / 0.587;
    return float4(clamp(float3(r, g, b), 0.0, 1.0), color.a);
}

/// ダイレクトフラッシュ。Core Image の作業色空間はリニア（光の量に比例）なので、明るさをそのまま比べられる。
/// photoLow: フラッシュ写真をぼかしたもの、ambientLow: 発光直前のコマ（周りの光だけ）をぼかしたもの。
/// ratio: コマの明るさを写真の露出にそろえる倍率。ambientGain: 周りの光を何倍にするか（0.25 で 2 段暗く）。
/// 写真の明るさのうち周りの光の割合 f を求め、明るさの倍率 (1 - f) + f * ambientGain を灰色の値で返す
/// ＝フラッシュの光はそのまま、周りの光だけを減らす。縮めた画像で計算し、引き伸ばしてから掛ける。
float4 directFlash(sampler photoLow, sampler ambientLow, sampler photoCoarse, sampler ambientCoarse,
                   float ratio, float ambientGain, destination dest) {
    float2 coord = dest.coord();
    float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    float total = dot(photoLow.sample(photoLow.transform(coord)).rgb, lumaWeights);
    float ambient = dot(ambientLow.sample(ambientLow.transform(coord)).rgb, lumaWeights) * ratio;
    float f = clamp(ambient / max(total, 0.0005), 0.0, 1.0);
    // フラッシュは光を足すだけなので、写真が発光前のコマより暗いことは本来ない。
    // 大きく暗い所は、人や手が動いて発光前と写っている物が違う所なので、広い範囲で求めた割合を使う
    // （そのまま使うと、動いた所が真っ黒な影や白い縁になっていた）
    float coarseTotal = dot(photoCoarse.sample(photoCoarse.transform(coord)).rgb, lumaWeights);
    float coarseAmbient = dot(ambientCoarse.sample(ambientCoarse.transform(coord)).rgb, lumaWeights) * ratio;
    float coarse = clamp(coarseAmbient / max(coarseTotal, 0.0005), 0.0, 1.0);
    // 写真とコマは iOS の明るさの仕上げ方が違うので、少し食い違うのはふつう。1.1 倍から広い範囲の割合にしていた頃は、
    // 顔のあちこちが広い範囲の割合（背景を含むので暗くする割合が大きい）になり、まだらに暗くなっていた。
    // 2 倍以上はっきり食い違う所（人や手が動いた所）だけにする
    float mismatch = smoothstep(2.0, 3.5, ambient / max(total, 0.0005));
    f = mix(f, coarse, mismatch);
    float gain = (1.0 - f) + f * ambientGain;
    return float4(gain, gain, gain, 1.0);
}

/// 青ひげ隠し（反対色で打ち消す）。剃り跡は、皮膚の下の毛が透けて「周りの肌より赤みが抜け、少し青く」見える
/// （実際の写真で測ると、頬より赤み Cr/Y が 1 割ほど低く、黄み（-Cb/Y）も少し低い。暗さの差はほとんどない）。
/// 画素ごとに、頬の色（skinSum / skinWeight: 目の下〜鼻の下の頬だけの平均）と比べ、
/// 赤みが足りない分・青みが多い分だけを、反対色（赤み・黄み）を足して打ち消す。
/// 色みは明るさで割った値（光の強さが変わっても同じ肌なら同じ値）で比べる。影（あご下・口元）は
/// この値では頬より赤いので、何も足さない（以前は影にも頬の色を足していて、あごがオレンジ色になっていた）。
/// 足すのは頬の色に届くまでで、それより先へは行かない。細かい質感（src - local）は残す。
/// 頬より大きく明るい所（鼻の下のテカリ）は、白っぽいのが光のせいなので変えない。
/// debug が 1 のときは、確認用に (効き具合, 参照できる肌の量 ×10, 色の足りなさ, 1) を色として返す。
float4 beardConceal(sampler src, sampler local, sampler skinSum, sampler skinWeight, float strength,
                    float debug, destination dest) {
    float2 coord = dest.coord();
    float4 color = src.sample(src.transform(coord));
    float weightSum = skinWeight.sample(skinWeight.transform(coord)).r;
    if (weightSum < 0.0005) {
        return debug > 0.5 ? float4(0.0, weightSum * 10.0, 0.0, 1.0) : color;
    }
    float3 lumaWeights = float3(0.299, 0.587, 0.114);
    float3 average = skinSum.sample(skinSum.transform(coord)).rgb / weightSum;
    float3 near = local.sample(local.transform(coord)).rgb;
    float averageY = max(dot(average, lumaWeights), 0.001);
    float nearY = max(dot(near, lumaWeights), 0.001);
    float2 averageC = float2(average.b - averageY, average.r - averageY) / averageY;
    float2 nearC = float2(near.b - nearY, near.r - nearY) / nearY;

    // 頬の色との差のうち、打ち消す向き（青みを減らす・赤みを足す）だけ。1 回に動かす量にも上限を付ける
    float2 deficit = averageC - nearC;
    deficit.x = clamp(deficit.x, -0.2, 0.0);
    deficit.y = clamp(deficit.y, 0.0, 0.25);
    float amount = clamp(length(deficit) / 0.08, 0.0, 1.0);

    float ratioY = nearY / averageY;
    float y = dot(color.rgb, lumaWeights);
    // 伸びたひげ・鼻の穴・濃い影・髪（とても暗い所）と、テカリ（頬よりずっと明るい所）は変えない
    float w = strength * smoothstep(0.08, 0.15, ratioY) * (1.0 - smoothstep(1.4, 2.0, ratioY));
    w *= smoothstep(0.08, 0.15, y / averageY);
    if (debug > 0.5) {
        return float4(w * amount, weightSum * 10.0, amount, 1.0);
    }

    float2 shift = deficit * w;
    float cb = color.b - y + shift.x * y;
    float cr = color.r - y + shift.y * y;
    // 剃り跡で少し暗くなった分も、色が足りない所だけ 3 割戻す（影の所は戻さない。戻すと平たく浮いて見える）
    float darker = max(0.0, averageY - nearY);
    float newY = y + darker * 0.3 * smoothstep(0.35, 0.55, ratioY) * w * amount;
    float r = newY + cr;
    float b = newY + cb;
    float g = (newY - 0.299 * r - 0.114 * b) / 0.587;
    return float4(clamp(float3(r, g, b), 0.0, 1.0), color.a);
}

/// a - b のうち正の部分（クロージングで明るくなった量）。不透明度は 1
float4 positiveDifference(sampler a, sampler b, destination dest) {
    float2 coord = dest.coord();
    float3 d = a.sample(a.transform(coord)).rgb - b.sample(b.transform(coord)).rgb;
    return float4(max(d, 0.0), 1.0);
}

/// base に delta の色を足す（不透明度は base のまま）
float4 addColor(sampler base, sampler delta, destination dest) {
    float2 coord = dest.coord();
    float4 color = base.sample(base.transform(coord));
    return float4(color.rgb + delta.sample(delta.transform(coord)).rgb, color.a);
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
