import UIKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import Photos

// MARK: - QR code

enum QRCode {
    static func detect(in image: UIImage) -> String? {
        guard let ci = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    static func generate(_ text: String, size: CGFloat = 600) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var onResult: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let frameView = UIView()
    private let hint = UILabel()
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        frameView.layer.borderColor = Theme.accent.cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = 16
        frameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameView)

        hint.text = L("Align QR code within frame to scan")
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let close = UIButton(type: .system)
        close.setImage(Theme.symbol("xmark", size: 20, weight: .semibold), for: .normal)
        close.tintColor = .white
        close.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        close.layer.cornerRadius = 22
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let album = UIButton(type: .system)
        album.setImage(Theme.symbol("photo.on.rectangle", size: 20), for: .normal)
        album.tintColor = .white
        album.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        album.layer.cornerRadius = 22
        album.addAction(UIAction { [weak self] _ in self?.pickPhoto() }, for: .touchUpInside)

        let torch = UIButton(type: .system)
        torch.setImage(Theme.symbol("flashlight.off.fill", size: 20), for: .normal)
        torch.tintColor = .white
        torch.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        torch.layer.cornerRadius = 22
        torch.addAction(UIAction { _ in
            guard let d = AVCaptureDevice.default(for: .video), d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            d.torchMode = d.torchMode == .on ? .off : .on
            torch.setImage(Theme.symbol(d.torchMode == .on ? "flashlight.on.fill" : "flashlight.off.fill", size: 20), for: .normal)
            d.unlockForConfiguration()
        }, for: .touchUpInside)

        for b in [close, album, torch] {
            b.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(b)
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 44), b.heightAnchor.constraint(equalToConstant: 44)])
        }

        NSLayoutConstraint.activate([
            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.68),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor),
            hint.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            album.trailingAnchor.constraint(equalTo: view.centerXAnchor, constant: -30),
            album.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            torch.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 30),
            torch.bottomAnchor.constraint(equalTo: album.bottomAnchor),
        ])
        setupCamera()
    }

    private func setupCamera() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok, let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                    self.hint.text = L("Camera is not available. You can pick a photo instead.")
                    return
                }
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    output.metadataObjectTypes = output.availableMetadataObjectTypes.filter { [.qr, .ean13, .ean8, .code128, .dataMatrix, .aztec, .pdf417].contains($0) }
                }
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.insertSublayer(layer, at: 0)
                self.preview = layer
                DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        finish(s)
    }

    private func finish(_ s: String) {
        handled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.stopRunning()
        let cb = onResult
        dismiss(animated: true) { cb?(s) }
    }

    private func pickPhoto() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true) {
            guard let img = info[.originalImage] as? UIImage, let s = QRCode.detect(in: img) else {
                Toast.show(L("qrcode.nocode"))
                return
            }
            self.finish(s)
        }
    }
}

// MARK: - Image saving

enum PhotoSaver {
    static func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else { Toast.show(L("Photo access denied")); return }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                Toast.show(L("Saved to Photos"))
            }
        }
    }
}

// MARK: - Image preview

final class ImagePreviewViewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let caption: String?
    private let scroll = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage, caption: String? = nil) {
        self.image = image
        self.caption = caption
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareImage)),
            UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), style: .plain, target: self, action: #selector(saveImage)),
        ]
        scroll.delegate = self
        scroll.maximumZoomScale = 6
        view.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        scroll.addSubview(imageView)

        let cap = UILabel()
        cap.text = caption
        cap.numberOfLines = 3
        cap.font = .systemFont(ofSize: 13)
        cap.textColor = .secondaryLabel
        cap.textAlignment = .center
        cap.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cap)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: cap.topAnchor, constant: -8),
            cap.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            cap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.zoomScale == 1 else { return }
        let w = scroll.bounds.width
        let isLong = image.size.height / max(image.size.width, 1) > scroll.bounds.height / max(w, 1)
        if isLong {
            let h = w * image.size.height / max(image.size.width, 1)
            imageView.frame = CGRect(x: 0, y: 0, width: w, height: h)
        } else {
            imageView.frame = scroll.bounds
        }
        scroll.contentSize = imageView.frame.size
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func close() { dismiss(animated: true) }
    @objc private func shareImage() { share([image]) }
    @objc private func saveImage() { PhotoSaver.save(image) }
}

// MARK: - Text viewer

final class TextViewerViewController: UIViewController, UISearchBarDelegate {
    private let text: String
    private let monospaced: Bool
    private let textView = UITextView()

    init(title: String, text: String, monospaced: Bool) {
        self.text = text
        self.monospaced = monospaced
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareText)),
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(copyText)),
        ]
        textView.text = text
        textView.isEditable = false
        textView.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 16)
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        view.addSubview(textView)
        textView.pinEdges(to: view)
        let search = UISearchController()
        search.searchBar.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let q = searchBar.text, !q.isEmpty else { return }
        let ns = textView.text as NSString
        let start = textView.selectedRange.location + textView.selectedRange.length
        var r = ns.range(of: q, options: .caseInsensitive, range: NSRange(location: min(start, ns.length), length: ns.length - min(start, ns.length)))
        if r.location == NSNotFound { r = ns.range(of: q, options: .caseInsensitive) }
        guard r.location != NSNotFound else { Toast.show(L("No results")); return }
        textView.selectedRange = r
        textView.scrollRangeToVisible(r)
        textView.becomeFirstResponder()
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func shareText() { share([text]) }
    @objc private func copyText() { UIPasteboard.general.string = text; Toast.show(L("Copied")) }
}

// MARK: - Page images gallery

final class GalleryViewController: UICollectionViewController {
    var onSave: ((URL) -> Void)?
    private let urls: [URL]
    private let cache = NSCache<NSURL, UIImage>()

    init(urls: [URL]) {
        self.urls = urls
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        super.init(collectionViewLayout: layout)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = LF("%d Images", urls.count)
        collectionView.backgroundColor = .systemBackground
        collectionView.register(GalleryCell.self, forCellWithReuseIdentifier: "c")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Save All"), style: .plain, target: self, action: #selector(saveAll))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let layout = collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let cols: CGFloat = view.bounds.width > 600 ? 5 : 3
        let w = floor((view.bounds.width - (cols - 1) * 2) / cols)
        layout.itemSize = CGSize(width: w, height: w)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func saveAll() {
        confirm(LF("Save %d images to Photos?", urls.count), action: L("Save")) { [weak self] in
            self?.urls.forEach { self?.onSave?($0) }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath) as! GalleryCell
        let url = urls[indexPath.item]
        cell.tag = indexPath.item
        if let img = cache.object(forKey: url as NSURL) {
            cell.imageView.image = img
        } else {
            cell.imageView.image = nil
            ImageLoader.load(url) { [weak self] img in
                guard let img else { return }
                self?.cache.setObject(img, forKey: url as NSURL)
                if cell.tag == indexPath.item { cell.imageView.image = img }
            }
        }
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let url = urls[indexPath.item]
        guard let img = cache.object(forKey: url as NSURL) else { return }
        navigationController?.pushViewController(ImagePreviewViewController(image: img, caption: url.absoluteString), animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first else { return nil }
        let url = urls[ip.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: L("Save Image"), image: UIImage(systemName: "square.and.arrow.down")) { _ in self?.onSave?(url) },
                UIAction(title: L("Copy Image URL"), image: UIImage(systemName: "link")) { _ in UIPasteboard.general.url = url; Toast.show(L("Copied")) },
                UIAction(title: L("Share"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    if let img = self?.cache.object(forKey: url as NSURL) { self?.share([img]) } else { self?.share([url]) }
                },
            ])
        }
    }
}

final class GalleryCell: UICollectionViewCell {
    let imageView = UIImageView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
        imageView.pinEdges(to: contentView)
    }
    required init?(coder: NSCoder) { fatalError() }
}
