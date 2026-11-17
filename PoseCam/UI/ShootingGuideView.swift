import SwiftUI

/// 撮ってもらう人ガイド。撮影画面の左に「撮影目標」のチェックリストを出す（判定は ShootingGuide）。
/// できた項目は黄色のチェック、できていない項目は下に撮る人への指示を出す。
struct ShootingGuideView: View {
    @ObservedObject var feed: PoseFeed
    let template: PoseTemplate?
    @StateObject private var motion = MotionReader()

    /// 縦持ち・横持ちのどちらでも、近い方の向き（0・90・180・270 度）からのずれ。寝かせているときは nil
    private var tilt: Double? {
        guard !motion.isFlat else { return nil }
        let roll = motion.roll
        return roll - (roll / 90).rounded() * 90
    }

    var body: some View {
        let items = ShootingGuide.items(tilt: tilt, pose: feed.detected, personTop: feed.personTop,
                                        face: feed.face, template: template)
        let allDone = !items.isEmpty && items.allSatisfy(\.isDone)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold))
                Text(allDone ? "撮影目標 クリア" : "撮影目標").font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(allDone ? Color.yellow : .white)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(item.isDone ? Color.yellow : .white.opacity(0.7))
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    if let hint = item.hint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.yellow.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 21)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 200, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.55)))
        .animation(.easeOut(duration: 0.15), value: items)
        // 端末の「文字の大きさ」を大きくしても、映像を覆い尽くさないようにする
        .dynamicTypeSize(...DynamicTypeSize.large)
        .environment(\.colorScheme, .dark)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}
