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

/// 周りより暗い部分（シミ・シワ）を、周りの平均の色で埋める。
/// mean: 元の画像をぼかしたもの（周りの平均）。暗さの差が low〜high の間で効き始め、high 以上で最大になる。
/// 明るい部分（ハイライト）や、周りと同じ明るさの所は変えない。
float4 darkSpotRemoval(sampler src, sampler mean, float strength, float low, float high, destination dest) {
    float2 coord = dest.coord();
    float4 color = src.sample(src.transform(coord));
    float4 average = mean.sample(mean.transform(coord));
    float3 lumaWeights = float3(0.299, 0.587, 0.114);
    float darker = dot(average.rgb, lumaWeights) - dot(color.rgb, lumaWeights);
    float weight = smoothstep(low, high, darker) * strength;
    return float4(mix(color.rgb, average.rgb, weight), color.a);
}

}
}
