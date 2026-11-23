import SwiftUI
import Photos
import AVKit

/// Xem ảnh / video toàn màn hình. Vuốt xuống để đóng, nút gửi thẳng sang Mac.
struct AssetViewer: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let send: (PHAsset) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var progress: Double?
    @State private var drag: CGFloat = 0
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, Double(abs(drag)) / 500)).ignoresSafeArea()
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(zoom)
                        .gesture(MagnifyGesture().onChanged { zoom = max(1, $0.magnification) }
                            .onEnded { _ in withAnimation(.spring) { zoom = 1 } })
                } else {
                    ProgressView(value: progress ?? 0).frame(width: 120).tint(Theme.glow)
                }
            }
            .offset(y: drag)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { v in
                if zoom == 1, v.translation.height > 0 { drag = v.translation.height }
            }.onEnded { v in
                if v.translation.height > 140 { dismiss() } else { withAnimation(.spring) { drag = 0 } }
            })
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if let date = asset.creationDate {
                        Text(date, format: .dateTime.day().month().year().hour().minute())
                            .font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16)
                Spacer()
                Button {
                    send(asset)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        PlaneGlyph().fill(.black).frame(width: 18, height: 15)
                        Text(L("Gửi sang Mac", "Send to Mac")).font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.brand, in: Capsule())
                }
                .padding(.bottom, 20)
            }
            .opacity(drag > 0 ? 0 : 1)
        }
        .statusBarHidden()
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func load() async {
        if asset.mediaType == .video {
            let opts = PHVideoRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .automatic
            opts.progressHandler = { p, _, _, _ in DispatchQueue.main.async { progress = p } }
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { item, _ in
                guard let item else { return }
                DispatchQueue.main.async {
                    let p = AVPlayer(playerItem: item)
                    player = p
                    p.play()
                }
            }
        } else {
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .opportunistic
            opts.progressHandler = { p, _, _, _ in DispatchQueue.main.async { progress = p } }
            let scale = UIScreen.main.scale
            let size = CGSize(width: UIScreen.main.bounds.width * scale * 1.5, height: UIScreen.main.bounds.height * scale * 1.5)
            library.images.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: opts) { img, _ in
                if let img { image = img }
            }
        }
    }
}
