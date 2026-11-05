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
    float weight = smoothstep(0.004, 0.04, excess) * strength;

    float newCr = mix(cr, averageCr, weight);
    float newCb = mix(cb, averageCb, weight);
    float newY = y + max(0.0, averageY - y) * weight * 0.6;

    float r = newY + newCr;
    float b = newY + newCb;
    float g = (newY - 0.299 * r - 0.114 * b) / 0.587;
    return float4(clamp(float3(r, g, b), 0.0, 1.0), color.a);
}

}
}
