import UIKit
import LocalAuthentication

// MARK: - Game

/// Caro (five in a row) on a square board. The player is X (1) and moves first; the computer is O (2).
struct CaroBoard {
    static let size = 12
    static let count = size * size
    private static let directions = [(0, 1), (1, 0), (1, 1), (1, -1)]

    private(set) var cells = [Int](repeating: 0, count: CaroBoard.count)
    private(set) var moves: [Int] = []

    var isFull: Bool { moves.count == CaroBoard.count }
    subscript(i: Int) -> Int { cells[i] }

    mutating func play(_ i: Int, _ player: Int) {
        cells[i] = player
        moves.append(i)
    }

    private func at(_ r: Int, _ c: Int) -> Int? {
        r >= 0 && r < Self.size && c >= 0 && c < Self.size ? cells[r * Self.size + c] : nil
    }

    /// The five (or more) in a row through `i`, if the stone there completes one.
    func winningLine(through i: Int) -> [Int]? {
        let p = cells[i]
        guard p != 0 else { return nil }
        let r = i / Self.size, c = i % Self.size
        for (dr, dc) in Self.directions {
            var line = [i]
            for s in [1, -1] {
                var k = 1
                while at(r + dr * k * s, c + dc * k * s) == p {
                    line.append((r + dr * k * s) * Self.size + c + dc * k * s)
                    k += 1
                }
            }
            if line.count >= 5 { return line }
        }
        return nil
    }

    /// Heuristic reply for `player`: weighs extending its own lines against blocking the opponent's.
    func bestMove(for player: Int, avoiding avoid: Set<Int> = []) -> Int? {
        let empty = (0..<Self.count).filter { cells[$0] == 0 && !avoid.contains($0) }
        guard !empty.isEmpty else { return nil }
        let near = empty.filter { i in
            let r = i / Self.size, c = i % Self.size
            for dr in -2...2 { for dc in -2...2 where (at(r + dr, c + dc) ?? 0) != 0 { return true } }
            return false
        }
        let candidates = near.isEmpty ? empty : near
        let opponent = 3 - player
        let center = Double(Self.size - 1) / 2
        var scored: [(Double, Int)] = candidates.map { i in
            let r = Double(i / Self.size), c = Double(i % Self.size)
            let centrality = -(abs(r - center) + abs(c - center)) * 0.5
            return (Double(lineScore(i, player)) * 1.15 + Double(lineScore(i, opponent)) + centrality, i)
        }
        scored.sort { $0.0 > $1.0 }
        let top = scored[0].0
        let close = scored.prefix { $0.0 >= top - max(2, abs(top) * 0.04) }
        return close.randomElement()?.1
    }

    private func lineScore(_ i: Int, _ p: Int) -> Int {
        let r = i / Self.size, c = i % Self.size
        var total = 0
        for (dr, dc) in Self.directions {
            var run = 1, open = 0
            for s in [1, -1] {
                var k = 1
                while at(r + dr * k * s, c + dc * k * s) == p { run += 1; k += 1 }
                if at(r + dr * k * s, c + dc * k * s) == 0 { open += 1 }
            }
            switch (min(run, 5), open) {
            case (5, _): total += 100_000
            case (4, 2): total += 12_000
            case (4, 1): total += 1_500
            case (3, 2): total += 1_200
            case (3, 1): total += 150
            case (2, 2): total += 100
            case (2, 1): total += 12
            case (1, 2): total += 8
            case (1, 1): total += 1
            default: break
            }
        }
        return total
    }
}

// MARK: - Board view

final class CaroBoardView: UIView {
    var board = CaroBoard() { didSet { setNeedsDisplay() } }
    var winningLine: [Int] = [] { didSet { setNeedsDisplay() } }
    /// Small move numbers drawn on cells (used when recording the unlock moves).
    var numbers: [Int: Int] = [:] { didSet { setNeedsDisplay() } }
    var showsLastMove = true
    var onTap: ((Int) -> Void)?

    static let paper = UIColor(red: 0.98, green: 0.95, blue: 0.87, alpha: 1)
    static let xColor = UIColor(red: 0.85, green: 0.16, blue: 0.18, alpha: 1)
    static let oColor = UIColor(red: 0.13, green: 0.36, blue: 0.80, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.paper
        layer.cornerRadius = 10
        layer.masksToBounds = true
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    private var cell: CGFloat { bounds.width / CGFloat(CaroBoard.size) }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        let c = Int(p.x / cell), r = Int(p.y / cell)
        guard r >= 0, r < CaroBoard.size, c >= 0, c < CaroBoard.size else { return }
        onTap?(r * CaroBoard.size + c)
    }

    private func rect(_ i: Int) -> CGRect {
        CGRect(x: CGFloat(i % CaroBoard.size) * cell, y: CGFloat(i / CaroBoard.size) * cell, width: cell, height: cell)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let n = CaroBoard.size
        if !winningLine.isEmpty {
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.35).cgColor)
            winningLine.forEach { ctx.fill(self.rect($0)) }
        }
        if showsLastMove, let last = board.moves.last, winningLine.isEmpty {
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.06).cgColor)
            ctx.fill(self.rect(last))
        }
        ctx.setStrokeColor(UIColor(red: 0.72, green: 0.64, blue: 0.50, alpha: 1).cgColor)
        ctx.setLineWidth(1 / UIScreen.main.scale)
        for k in 0...n {
            let v = CGFloat(k) * cell
            ctx.move(to: CGPoint(x: v, y: 0)); ctx.addLine(to: CGPoint(x: v, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: v)); ctx.addLine(to: CGPoint(x: bounds.width, y: v))
        }
        ctx.strokePath()

        let inset = cell * 0.24
        ctx.setLineWidth(max(2, cell * 0.11))
        ctx.setLineCap(.round)
        for i in 0..<CaroBoard.count where board[i] != 0 {
            let r = self.rect(i).insetBy(dx: inset, dy: inset)
            if board[i] == 1 {
                ctx.setStrokeColor(Self.xColor.cgColor)
                ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                ctx.strokePath()
            } else {
                ctx.setStrokeColor(Self.oColor.cgColor)
                ctx.strokeEllipse(in: r)
            }
        }
        let font = UIFont.systemFont(ofSize: max(8, cell * 0.3), weight: .bold)
        for (i, number) in numbers {
            let r = self.rect(i)
            ("\(number)" as NSString).draw(at: CGPoint(x: r.minX + 2, y: r.minY + 1), withAttributes: [.font: font, .foregroundColor: UIColor.darkGray])
        }
    }
}

// MARK: - Lock screen

/// Looks and plays like an ordinary caro game. The browser opens only when the player's first three
/// moves of a game are exactly the recorded ones; any other opening simply continues the game.
final class CaroLockView: UIView {
    var onUnlock: (() -> Void)?

    private let pattern: [Int]
    private let titleLabel = UILabel()
    private let scoreLabel = UILabel()
    private let statusLabel = UILabel()
    private let boardView = CaroBoardView()
    private let newGameButton = UIButton(type: .system)
    private var playerMoves: [Int] = []
    private var playerTurn = true
    private var over = false
    private var unlocked = false
    private var game = 0

    private static let winsKey = "caroWins", lossesKey = "caroLosses"

    init(frame: CGRect, pattern: [Int]) {
        self.pattern = pattern
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.95, green: 0.91, blue: 0.82, alpha: 1)
        overrideUserInterfaceStyle = .light

        titleLabel.text = L("Caro")
        titleLabel.font = .systemFont(ofSize: 30, weight: .heavy)
        titleLabel.textColor = UIColor(red: 0.35, green: 0.22, blue: 0.12, alpha: 1)
        titleLabel.textAlignment = .center
        titleLabel.isUserInteractionEnabled = true
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(fallbackUnlock(_:)))
        hold.minimumPressDuration = 3
        titleLabel.addGestureRecognizer(hold)

        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        scoreLabel.textColor = UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        scoreLabel.textAlignment = .center

        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.textColor = UIColor(red: 0.30, green: 0.22, blue: 0.15, alpha: 1)
        statusLabel.textAlignment = .center

        var config = UIButton.Configuration.filled()
        config.title = L("New Game")
        config.baseBackgroundColor = UIColor(red: 0.55, green: 0.35, blue: 0.18, alpha: 1)
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 26, bottom: 10, trailing: 26)
        newGameButton.configuration = config
        newGameButton.addTarget(self, action: #selector(newGame), for: .touchUpInside)

        boardView.onTap = { [weak self] i in self?.playerTapped(i) }
        [titleLabel, scoreLabel, statusLabel, boardView, newGameButton].forEach(addSubview)
        newGame()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 8)
        let header: CGFloat = 96, footer: CGFloat = 70
        let side = max(0, min(safe.width, safe.height - header - footer))
        let top = safe.minY + max(0, (safe.height - header - footer - side) / 2)
        titleLabel.frame = CGRect(x: safe.minX, y: top, width: safe.width, height: 38)
        scoreLabel.frame = CGRect(x: safe.minX, y: top + 40, width: safe.width, height: 20)
        statusLabel.frame = CGRect(x: safe.minX, y: top + 66, width: safe.width, height: 24)
        boardView.frame = CGRect(x: safe.midX - side / 2, y: top + header, width: side, height: side)
        let b = newGameButton.intrinsicContentSize
        newGameButton.frame = CGRect(x: safe.midX - b.width / 2, y: boardView.frame.maxY + 18, width: b.width, height: b.height)
    }

    private func updateScore() {
        let d = UserDefaults.standard
        scoreLabel.text = String(format: L("You %d – %d Computer"), d.integer(forKey: Self.winsKey), d.integer(forKey: Self.lossesKey))
    }

    @objc private func newGame() {
        game += 1
        boardView.board = CaroBoard()
        boardView.winningLine = []
        playerMoves = []
        playerTurn = true
        over = false
        statusLabel.text = L("Your turn (X)")
        updateScore()
    }

    private func playerTapped(_ i: Int) {
        guard playerTurn, !over, !unlocked, boardView.board[i] == 0 else { return }
        boardView.board.play(i, 1)
        playerMoves.append(i)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if playerMoves.count == 3, playerMoves == pattern {
            unlocked = true
            onUnlock?()
            return
        }
        if finishIfOver(after: i) { return }
        playerTurn = false
        statusLabel.text = L("Computer is thinking…")
        // The computer stays off the remaining unlock cells while the opening still matches,
        // so the right moves can always be played.
        let avoid: Set<Int> = playerMoves.count < 3 && Array(pattern.prefix(playerMoves.count)) == playerMoves ? Set(pattern) : []
        let board = boardView.board
        let current = game
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.game == current, !self.unlocked else { return }
            guard let move = board.bestMove(for: 2, avoiding: avoid) ?? board.bestMove(for: 2) else { return }
            self.boardView.board.play(move, 2)
            if self.finishIfOver(after: move) { return }
            self.playerTurn = true
            self.statusLabel.text = L("Your turn (X)")
        }
    }

    private func finishIfOver(after i: Int) -> Bool {
        if let line = boardView.board.winningLine(through: i) {
            over = true
            boardView.winningLine = line
            let playerWon = boardView.board[i] == 1
            let key = playerWon ? Self.winsKey : Self.lossesKey
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
            statusLabel.text = playerWon ? L("You win!") : L("Computer wins!")
            updateScore()
            UINotificationFeedbackGenerator().notificationOccurred(playerWon ? .success : .error)
            return true
        }
        if boardView.board.isFull {
            over = true
            statusLabel.text = L("Draw")
            return true
        }
        return false
    }

    #if DEBUG
    func debugTap(_ i: Int) { playerTapped(i) }
    #endif

    /// Hidden way back in when the moves are forgotten: hold the title, then pass device authentication.
    @objc private func fallbackUnlock(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, !unlocked else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Authentication")) { ok, _ in
            DispatchQueue.main.async {
                guard ok, !self.unlocked else { return }
                self.unlocked = true
                self.onUnlock?()
            }
        }
    }
}

// MARK: - Recording the unlock moves

final class CaroPatternViewController: UIViewController {
    var onSaved: (() -> Void)?

    private let infoLabel = UILabel()
    private let boardView = CaroBoardView()
    private var first: [Int] = []
    private var current: [Int] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Caro Lock")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Reset"), style: .plain, target: self, action: #selector(reset))
        infoLabel.numberOfLines = 0
        infoLabel.textAlignment = .center
        infoLabel.font = .systemFont(ofSize: 15)
        infoLabel.textColor = .secondaryLabel
        boardView.showsLastMove = false
        boardView.onTap = { [weak self] i in self?.tapped(i) }
        view.addSubview(infoLabel)
        view.addSubview(boardView)
        reset()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 16, dy: 12)
        let infoHeight: CGFloat = 70
        infoLabel.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: infoHeight)
        let side = max(0, min(safe.width, safe.height - infoHeight - 8))
        boardView.frame = CGRect(x: safe.midX - side / 2, y: safe.minY + infoHeight + 8, width: side, height: side)
    }

    @objc private func reset() {
        first = []
        clearBoard()
        infoLabel.text = L("Tap the 3 opening moves that will unlock FAbrowser. Order matters.")
        infoLabel.textColor = .secondaryLabel
    }

    private func clearBoard() {
        current = []
        boardView.board = CaroBoard()
        boardView.numbers = [:]
        boardView.isUserInteractionEnabled = true
    }

    private func tapped(_ i: Int) {
        guard current.count < 3, boardView.board[i] == 0 else { return }
        boardView.board.play(i, 1)
        current.append(i)
        boardView.numbers[i] = current.count
        guard current.count == 3 else { return }
        boardView.isUserInteractionEnabled = false
        if first.isEmpty {
            first = current
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.clearBoard()
                self?.infoLabel.text = L("Play the same 3 moves again to confirm.")
            }
        } else if current == first {
            Prefs.caroLockMoves = first.map(String.init).joined(separator: ",")
            Prefs.caroLock = true
            Prefs.requireUnlock = false
            Toast.show(L("Caro Lock is on"))
            onSaved?()
            navigationController?.popViewController(animated: true)
        } else {
            infoLabel.text = L("The moves didn't match. Start again.")
            infoLabel.textColor = .systemRed
            first = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.clearBoard() }
        }
    }
}

extension Prefs {
    /// The recorded unlock moves, when Caro Lock is on and set up.
    static var caroLockPattern: [Int]? {
        let moves = caroLockMoves.split(separator: ",").compactMap { Int($0) }
        return caroLock && moves.count == 3 && moves.allSatisfy({ $0 >= 0 && $0 < CaroBoard.count }) ? moves : nil
    }
}
