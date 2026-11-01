import SwiftUI
import UIKit

/// A page image with pinch-to-zoom, double-tap zoom, and tap reporting.
/// `onTap` receives where the tap landed horizontally (0 = left edge, 1 = right edge).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: (CGFloat) -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onTap = onTap
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onTap = onTap
        if view.imageView.image !== image { view.setImage(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale + 0.001 {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = g.location(in: imageView)
            let scale: CGFloat = 2.5
            let w = bounds.width / scale
            let h = bounds.height / scale
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        // While zoomed in, taps only toggle the controls (no accidental page turns).
        if zoomScale > minimumZoomScale + 0.01 {
            onTap?(0.5)
            return
        }
        let x = g.location(in: self).x
        onTap?(bounds.width > 0 ? x / bounds.width : 0.5)
    }
}
