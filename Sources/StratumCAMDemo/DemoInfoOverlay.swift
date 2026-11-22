//
//  DemoInfoOverlay.swift
//  StratumCAM
//
//  Top-left panel on the canvas listing the operation, tool and machine settings of the
//  demo currently shown.
//

import SwiftUI

struct DemoInfoOverlay: View {

    let title: String?
    let info: DemoInfo

    var body: some View {
        // Fits on screen as is; on a short window it falls back to a scrollable panel.
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
        }
        .frame(width: 280, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(info.blocks.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}
