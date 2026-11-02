import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

/// The support chat. Present it in a sheet, a navigation destination or a tab.
public struct InngameChatView: View {
    @ObservedObject private var store = Inngame.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var sending = false
    @State private var faqQuery = ""
    @State private var articles: [InngameArticle] = []
    @State private var openArticle: InngameArticle?
    @FocusState private var focused: Bool
    private let showsClose: Bool

    public init(showsCloseButton: Bool = true) { self.showsClose = showsCloseButton }

    private var appearance: JSONValue? { store.config?.appearance }
    private var theme: ChatTheme { ChatTheme(appearance: appearance, dark: scheme == .dark) }
    private var accent: Color { theme.accent }
    private var title: String { appearance?["title"]?.string ?? L.t("Support") }

    /// Title bar: the app's logo (dashboard → Appearance), the title and the usual reply time.
    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if let url = theme.logoURL {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Circle().fill(accent.opacity(0.3)) }
                    .frame(width: 28, height: 28).clipShape(Circle())
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                Text(title).font(.headline)
                if let line = store.config?.availability?.text() { Text(line).font(.caption2).opacity(0.7) }
            }
        }
        .foregroundStyle(theme.text ?? Color.primary)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let note = appearance?["announcement"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    // The team's announcement (outage, maintenance, known bug), translated by the server.
                    HStack(spacing: 10) {
                        Rectangle().fill(accent).frame(width: 3)
                        Text(note).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.secondary.opacity(0.12))
                    .accessibilityElement(children: .combine)
                }
                if store.isUnavailable {
                    // The studio's support is unavailable (workspace suspended): one clear line, no composer.
                    Text(L.t("Support is unavailable right now. Please try again later."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityAddTraits(.isStaticText)
                } else {
                    if store.messages.isEmpty { welcome } else { thread }
                    if store.isBlocked {
                        Text(L.t("You can't send messages.")).font(.footnote).foregroundStyle(.secondary).padding()
                    } else { composer }
                }
            }
            .background((theme.background ?? Color.clear).ignoresSafeArea())
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
            .toolbarBackground(theme.header ?? Color.clear, for: .navigationBar)
            .toolbarBackground(theme.header == nil ? .automatic : .visible, for: .navigationBar)
            #endif
            .toolbar {
                if theme.logoURL != nil || store.config?.availability?.text() != nil || theme.text != nil {
                    ToolbarItem(placement: .principal) { header }
                }
                if showsClose {
                    ToolbarItem(placement: .cancellationAction) { Button(L.t("Close")) { dismiss() } }
                }
            }
            .sheet(item: $openArticle) { a in
                NavigationStack {
                    ScrollView { Text(a.body).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle(a.title)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L.t("Done")) { openArticle = nil } } }
                }
            }
        }
        .tint(accent)
        .onAppear { store.isChatVisible = true }
        .onDisappear { store.isChatVisible = false }
        .task { if store.config?.faq == true { articles = await store.searchFAQ("") } }
        .onChange(of: photo) { item in
            Task { photoData = try? await item?.loadTransferable(type: Data.self).flatMap(Self.jpeg) }
        }
    }

    // MARK: Welcome + FAQ

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(appearance?["welcomeTitle"]?.string ?? L.t("Hi! How can we help?")).font(.title2.bold())
                Text(appearance?["welcomeMessage"]?.string ?? L.t("Write to us here. We usually answer within a few hours, in your language."))
                    .foregroundStyle(.secondary)
                if store.config?.faq == true {
                    TextField(L.t("Search help articles"), text: $faqQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { articles = await store.searchFAQ(faqQuery) } }
                    ForEach(articles.prefix(6)) { a in
                        Button { openArticle = a } label: {
                            HStack { Text(a.title).multilineTextAlignment(.leading); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                                .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(20)
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.hasMore {
                        ProgressView().task { await store.loadOlder() }
                    }
                    ForEach(store.messages) { m in
                        MessageRow(message: m, language: store.user?.language, theme: theme) { action in
                            if action.hasPrefix("rated:"), let score = Int(action.dropFirst(6)) { Task { await store.rate(m, score: score) } }
                            else { Task { await store.cardAction(m, action: action) } }
                        }.id(m.id)
                    }
                    ForEach(store.pending) { p in
                        PendingRow(message: p, theme: theme) { Task { await store.retryPending() } }.id(p.id)
                    }
                    if store.isTeamTyping {
                        HStack { TypingDots().padding(10).background(.quaternary, in: Capsule()); Spacer() }.id("typing")
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
            .onChange(of: store.messages.last?.id) { id in withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: store.pending.last?.id) { id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            .onChange(of: store.isTeamTyping) { t in if t { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } } }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let err = store.lastError {
                Text(err).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { store.lastError = nil }
            }
            if let photoData, let img = Self.image(photoData) {
                HStack {
                    img.resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button { self.photoData = nil; photo = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(L.t("Remove photo"))
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if store.config?.photosEnabled != false {
                    PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo").font(.title3) }
                        .accessibilityLabel(L.t("Attach a photo"))
                }
                TextField(appearance?["placeholder"]?.string ?? L.t("Message"), text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                    .onChange(of: text) { _ in store.sendTyping() }
                Button {
                    let t = text, p = photoData
                    text = ""; photoData = nil; photo = nil; sending = true
                    Task { await store.send(t, imageData: p); sending = false }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(sending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photoData == nil))
                .accessibilityLabel(L.t("Send"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    static func jpeg(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let img = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.8)
        #else
        return data
        #endif
    }

    static func image(_ data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map(Image.init(uiImage:))
        #else
        return NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

struct MessageRow: View {
    let message: InngameMessage
    let language: String?
    let theme: ChatTheme
    private var accent: Color { theme.accent }
    let onCard: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        let mine = message.isFromPlayer
        if message.authorType == .system, let card = message.parsedCard {
            // Cards the server sends on its own (satisfaction at close, then the store review): same place as the team's cards.
            HStack {
                CardView(card: card, accent: accent, onAction: onCard)
                Spacer(minLength: 48)
            }
        } else if message.authorType == .system {
            Text(message.body).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            HStack {
                if mine { Spacer(minLength: 48) }
                VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                    if !mine, let name = message.authorType == .ai ? L.t("Assistant") : message.author?.name {
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(message.attachments.filter(\.isImage), id: \.self) { a in
                        AsyncImage(url: a.url) { $0.resizable().scaledToFit() } placeholder: { ProgressView().frame(width: 160, height: 120) }
                            .frame(maxWidth: 240).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    let text = message.text(for: language)
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(mine ? theme.outgoingText : theme.incomingText)
                            .background(mine ? theme.outgoing : theme.incoming, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let card = message.parsedCard { CardView(card: card, accent: accent, onAction: onCard) }
                }
                if !mine { Spacer(minLength: 48) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A message not yet accepted by the server: dimmed, with "Sending…" or a retry button.
struct PendingRow: View {
    let message: InngamePendingMessage
    let theme: ChatTheme
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.body)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(theme.outgoingText)
                    .background(theme.outgoing.opacity(message.failed ? 0.45 : 0.7), in: RoundedRectangle(cornerRadius: 18))
                if message.failed {
                    Button(L.t("Not sent · Tap to retry"), action: onRetry).font(.caption2).foregroundStyle(.red)
                } else {
                    Text(L.t("Sending…")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CardView: View {
    let card: InngameCard
    let accent: Color
    let onAction: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if card.kind == "rating" { RatingView(card: card, accent: accent, onRate: { onAction("rated:\($0)") }) } else { button }
    }

    private var button: some View {
        Button {
            onAction("tapped")
            switch card.kind {
            case "review": requestReview()
            case "refund": requestRefund()
            default: if let url = card.url, Inngame.isSafeCardURL(url) { openURL(url) }
            }
        } label: {
            Label(card.displayLabel(), systemImage: icon)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private var icon: String { ["review": "star.fill", "refund": "arrow.uturn.backward", "offer": "gift.fill", "item": "gift.fill"][card.kind] ?? "arrow.up.right" }

    private func requestReview() {
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            SKStoreReviewControllerShim.request(in: scene)
        }
        #endif
    }

    private func requestRefund() {
        #if os(iOS)
        guard let id = card.raw["transactionId"]?.string, let tx = UInt64(id) else { return }
        Task { @MainActor in
            if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                let ok = await RefundShim.begin(transactionID: tx, in: scene)
                onAction(ok ? "claimed" : "failed")
            }
        }
        #endif
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().frame(width: 6, height: 6).opacity(0.3 + 0.7 * max(0, sin(phase + Double(i) * 0.8)))
            }
        }
        .foregroundStyle(.secondary)
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
        .accessibilityLabel(L.t("Support is typing"))
    }
}

extension Color {
    init?(hex: String?) {
        guard let (r, g, b) = Color.rgb(hex) else { return nil }
        self.init(red: r, green: g, blue: b)
    }

    /// Composantes d'un "#RRGGBB" (0…1), nil sinon.
    static func rgb(_ hex: String?) -> (Double, Double, Double)? {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Texte lisible sur ce fond : même seuil que les autres SDK (sombre sur clair, blanc sinon).
    static func readable(on hex: String?) -> Color {
        guard let (r, g, b) = rgb(hex) else { return .white }
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6 ? Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1f / 255) : .white
    }
}

/// Couleurs et logo du chat (tableau de bord → Apparence). En-tête et bulles gardent l'aspect système tant que le studio ne les choisit pas.
struct ChatTheme {
    let accent: Color
    let background: Color?
    let text: Color?
    let header: Color?
    let incoming: Color
    let incomingText: Color
    let outgoing: Color
    let outgoingText: Color
    let logoURL: URL?

    init(appearance: JSONValue?, dark: Bool) {
        let p = appearance?[dark ? "dark" : "light"]
        let hex = { (k: String) -> String? in p?[k]?.string.flatMap { Color.rgb($0) != nil ? $0 : nil } }
        accent = Color(hex: hex("accent")) ?? .accentColor
        background = Color(hex: hex("background"))
        text = Color(hex: hex("text"))
        header = Color(hex: hex("header"))
        if let inc = hex("incoming") { incoming = Color(hex: inc)!; incomingText = Color.readable(on: inc) }
        else { incoming = Color.secondary.opacity(0.15); incomingText = text ?? .primary }
        let out = hex("outgoing") ?? hex("accent")
        outgoing = Color(hex: out) ?? .accentColor
        outgoingText = out.map { Color.readable(on: $0) } ?? .white
        let logo = appearance?["logoUrl"]?.string.flatMap(URL.init(string:))
        logoURL = logo?.scheme == "https" || logo?.scheme == "http" ? logo : nil
    }
}

/// Satisfaction: the question in the user's language and five buttons (1 to 5). Rated once; the server keeps the first score.
struct RatingView: View {
    let card: InngameCard
    let accent: Color
    let onRate: (Int) -> Void
    @State private var picked: Int?

    private var rating: Int? { picked ?? card.raw["rating"]?.number.map { Int($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rating {
                Text("\(L.t("Thanks for your feedback!")) (\(rating)/5)").font(.callout)
            } else {
                Text(L.t("How did we do?")).font(.callout.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { score in
                        Button { picked = score; onRate(score) } label: {
                            Text("\(score)").font(.callout.weight(.bold)).frame(width: 40, height: 40)
                                .foregroundStyle(.white)
                                .background(accent.opacity(0.45 + 0.11 * Double(score)), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(score) / 5")
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
