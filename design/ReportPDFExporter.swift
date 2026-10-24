//  ReportPDFExporter.swift
//  Report A4 con campi compilabili (note, firme, spunte "Fatto").
//
//  Come funziona:
//  1. Ogni pagina è una normale View SwiftUI di 595×842 pt (A4).
//  2. I campi sono descritti UNA volta sola in `ReportField` (rettangolo in punti, origine in alto a sinistra).
//     `FieldLayer` li disegna sulla pagina (riquadro azzurro) e l'esportatore crea nello stesso punto
//     il campo PDF vero (PDFAnnotation widget). Disegno e campo non possono andare fuori registro.
//  3. ImageRenderer scrive le pagine in un PDF vettoriale; PDFKit aggiunge i campi e salva.

import SwiftUI
import PDFKit
import AppKit

enum A4 {
    static let size = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 45
}

struct ReportField: Identifiable, Sendable {
    enum Kind: Sendable {
        case text(multiline: Bool = false, value: String = "")
        case checkbox
    }
    let name: String          // nome univoco del campo nel PDF, es. "cliente", "todo.1"
    let rect: CGRect          // in punti, origine in alto a sinistra della pagina
    let kind: Kind
    var id: String { name }
}

/// Disegna i riquadri dei campi. Mettilo in `.overlay(alignment: .topLeading)` della pagina.
struct FieldLayer: View {
    let fields: [ReportField]
    static let fill = Color(red: 0.953, green: 0.969, blue: 0.992)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(fields) { f in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.fill)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.56), lineWidth: 0.75))
                    .frame(width: f.rect.width, height: f.rect.height)
                    .offset(x: f.rect.minX, y: f.rect.minY)
            }
        }
        .frame(width: A4.size.width, height: A4.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

struct ReportPage: Identifiable {
    let id = UUID()
    let content: AnyView
    let fields: [ReportField]

    init<V: View>(fields: [ReportField] = [], @ViewBuilder _ content: () -> V) {
        self.fields = fields
        self.content = AnyView(
            content()
                .frame(width: A4.size.width, height: A4.size.height, alignment: .topLeading)
                .overlay(alignment: .topLeading) { FieldLayer(fields: fields) }
                .background(Color.white)
                .environment(\.colorScheme, .light)   // il report è sempre chiaro, anche se l'app è scura
        )
    }
}

enum ReportExportError: Error { case cannotCreateContext, cannotReopen, cannotWrite }

@MainActor
enum ReportPDFExporter {

    /// Esporta le pagine in `url`. Con `fillable == false` i riquadri restano disegnati ma non editabili.
    static func export(pages: [ReportPage], to url: URL, title: String, fillable: Bool = true) throws {
        // 1) Pagine vettoriali
        var box = CGRect(origin: .zero, size: A4.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "[Nome app]"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ReportExportError.cannotCreateContext
        }
        for page in pages {
            let renderer = ImageRenderer(content: page.content)
            renderer.proposedSize = ProposedViewSize(A4.size)
            renderer.render { _, draw in
                ctx.beginPDFPage(nil)
                draw(ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()

        guard fillable else { return }

        // 2) Campi compilabili
        guard let doc = PDFDocument(url: url) else { throw ReportExportError.cannotReopen }
        for (index, page) in pages.enumerated() {
            guard let pdfPage = doc.page(at: index) else { continue }
            let height = pdfPage.bounds(for: .mediaBox).height
            for field in page.fields {
                // PDF ha l'origine in basso a sinistra
                let r = field.rect
                let bounds = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
                pdfPage.addAnnotation(widget(for: field, bounds: bounds))
            }
        }
        guard doc.write(to: url) else { throw ReportExportError.cannotWrite }
    }

    private static func widget(for field: ReportField, bounds: CGRect) -> PDFAnnotation {
        let w = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        w.fieldName = field.name
        w.backgroundColor = NSColor(srgbRed: 0.953, green: 0.969, blue: 0.992, alpha: 1)
        let border = PDFBorder()
        border.lineWidth = 0.75
        w.border = border
        w.color = NSColor(white: 0.56, alpha: 1)

        switch field.kind {
        case let .text(multiline, value):
            w.widgetFieldType = .text
            w.isMultiline = multiline
            w.font = NSFont.systemFont(ofSize: multiline ? 10 : 11)
            w.fontColor = .black
            w.widgetStringValue = value
            w.alignment = .left
        case .checkbox:
            w.widgetFieldType = .button
            w.widgetControlType = .checkBoxControl
            w.buttonWidgetStateString = "Fatto"
            w.buttonWidgetState = .offState
        }
        return w
    }
}

// MARK: - Esempio d'uso: pagina 1 (intestazione + "Cosa fare")

/// Coordinate dei campi della pagina 1, in punti (stessi valori usati dal layout).
enum Page1Fields {
    static let colW: CGFloat = (A4.size.width - A4.margin * 2 - 18) / 3
    static let all: [ReportField] = [
        .init(name: "cliente",   rect: CGRect(x: A4.margin,                  y: 150, width: colW, height: 22), kind: .text()),
        .init(name: "indirizzo", rect: CGRect(x: A4.margin + colW + 9,       y: 150, width: colW, height: 22), kind: .text()),
        .init(name: "tecnico",   rect: CGRect(x: A4.margin + (colW + 9) * 2, y: 150, width: colW, height: 22), kind: .text(value: "Marco")),
        .init(name: "todo.1", rect: CGRect(x: A4.margin, y: 520, width: 12, height: 12), kind: .checkbox),
        .init(name: "todo.2", rect: CGRect(x: A4.margin, y: 566, width: 12, height: 12), kind: .checkbox),
        .init(name: "todo.3", rect: CGRect(x: A4.margin, y: 612, width: 12, height: 12), kind: .checkbox),
    ]
}

struct ReportPage1: View {
    let score: Int
    let level: StatusLevel
    let summary: String
    let todos: [(title: String, detail: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 0.75, dash: [3]))
                    .frame(width: 90, height: 27)
                    .overlay(Text("[Il tuo logo]").font(.system(size: 8)).foregroundStyle(.secondary))
                Spacer()
                Text(Date.now, format: .dateTime.day().month(.wide).year())
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 9)
            .overlay(alignment: .bottom) { Rectangle().frame(height: 1.5) }

            Text("Report della rete Wi‑Fi").font(.system(size: 24, weight: .bold)).padding(.top, 18)

            // Etichette sopra i campi (i riquadri li disegna FieldLayer a y = 150)
            HStack(spacing: 9) {
                ForEach(["CLIENTE", "INDIRIZZO", "TECNICO"], id: \.self) {
                    Text($0).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 14)
            Spacer().frame(height: 30)

            HStack(spacing: 16) {
                HealthGauge(score: score, level: level, size: 84)
                VStack(alignment: .leading, spacing: 4) {
                    StatusBadge(level: level)
                    Text(summary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 8))

            Text("Cosa fare").font(.system(size: 13, weight: .bold)).padding(.top, 150)
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.title).font(.system(size: 10, weight: .semibold))
                    Text(todo.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.leading, 22)          // lascia spazio alla casella "Fatto"
                .frame(height: 46, alignment: .topLeading)
            }
            Spacer()
        }
        .padding(A4.margin)
        .foregroundStyle(.black)
    }
}

// Uso (es. dal pulsante "Esporta PDF…" della vista Esporta):
//
// let panel = NSSavePanel()
// panel.allowedContentTypes = [.pdf]
// panel.nameFieldStringValue = "Report Wi‑Fi.pdf"
// if panel.runModal() == .OK, let url = panel.url {
//     let page1 = ReportPage(fields: Page1Fields.all) {
//         ReportPage1(score: 76, level: .good,
//                     summary: "La rete funziona bene, ma un router vicino usa lo stesso canale a 5 GHz.",
//                     todos: [("Spostare il 5 GHz dal canale 36 al 52", "FRITZ!Box › Wi‑Fi › Canale radio."),
//                             ("Spostare il 2,4 GHz dal canale 6 all'1", "Sul 6 c'è anche FORZAMAG a 40 MHz."),
//                             ("Riconoscere il dispositivo 192.168.179.189", "Collegato oggi alle 10:41.")])
//     }
//     try ReportPDFExporter.export(pages: [page1], to: url, title: "Report della rete Wi‑Fi")
// }
//
// Nota: le coordinate di Page1Fields vanno ritoccate una volta sul layout definitivo
// (aprendo il PDF in Anteprima con i campi evidenziati). Tenerle in un solo posto evita disallineamenti.
