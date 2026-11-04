import SwiftUI

struct FilterStrip: View {
    @Binding var selection: PhotoFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(PhotoFilter.allCases) { filter in
                    Button { selection = filter } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(filter.swatch)
                                .frame(width: 52, height: 52)
                                .overlay(Circle().stroke(selection == filter ? Color.yellow : .clear, lineWidth: 3))
                            Text(filter.displayName)
                                .font(.caption2)
                                .foregroundStyle(selection == filter ? Color.yellow : .white)
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

private extension PhotoFilter {
    var swatch: LinearGradient {
        let colors: [Color]
        switch self {
        case .none: colors = [.gray, .white]
        case .natural: colors = [.green, .yellow]
        case .warm: colors = [.orange, .yellow]
        case .cool: colors = [.blue, .cyan]
        case .pink: colors = [.pink, .white]
        case .film: colors = [.brown, .teal]
        case .chrome: colors = [.red, .blue]
        case .fade: colors = [.gray.opacity(0.6), .white.opacity(0.8)]
        case .instant: colors = [.orange, .mint]
        case .sepia: colors = [.brown, .orange.opacity(0.6)]
        case .mono: colors = [.black, .white]
        case .noir: colors = [.black, .gray]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct BeautyPanel: View {
    @Binding var settings: ProcessingSettings

    var body: some View {
        VStack(spacing: 2) {
            SliderRow(title: "美肌", value: $settings.smoothing)
            SliderRow(title: "美白", value: $settings.brightening)
            SliderRow(title: "脚長", value: $settings.legLength)
        }
        .padding(.horizontal)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 36, alignment: .leading)
            Slider(value: $value, in: 0...1)
                .tint(.yellow)
            Text("\(Int(value * 100))")
                .font(.caption.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }
}

struct ModePicker: View {
    let mode: CaptureMode
    let isLocked: Bool
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 28) {
            ForEach(CaptureMode.allCases) { item in
                Button { onSelect(item) } label: {
                    Text(item.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item == mode ? Color.yellow : .white.opacity(0.7))
                }
                .disabled(isLocked)
            }
        }
    }
}

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if mode == .photo {
                    Circle()
                        .fill(Color.white.opacity(isBusy ? 0.5 : 1))
                        .frame(width: 60, height: 60)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 6 : 30)
                        .fill(Color.red)
                        .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                }
            }
        }
        .disabled(mode == .photo && isBusy)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

/// 最後に撮った写真・動画。タップで写真アプリを開く。
struct ThumbnailButton: View {
    let image: UIImage?

    var body: some View {
        Button {
            if let url = URL(string: "photos-redirect://") {
                UIApplication.shared.open(url)
            }
        } label: {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ScoreBadge: View {
    let score: Double
    let matched: Bool

    var body: some View {
        Text("一致度 \(Int(score))%")
            .font(.subheadline.weight(.bold).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(matched ? Color.green : Color.black.opacity(0.55)))
            .foregroundStyle(.white)
    }
}

struct RecordingBadge: View {
    let seconds: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.subheadline.monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .foregroundStyle(.white)
    }
}

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("カメラへのアクセスが許可されていません")
                .font(.headline)
            Text("設定アプリでカメラへのアクセスを許可してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding()
    }
}
