import SwiftUI

struct StatusFooterView: View {
    let stats: SystemStatsSnapshot

    var body: some View {
        HStack(spacing: 24) {
            Text("Memory: \(Formatters.gigabytes(bytes: stats.usedMemory)) / \(Formatters.gigabytes(bytes: stats.totalMemory))")
            Text("Swap: \(Formatters.memory(bytes: stats.usedSwap))")
            Text(String(format: "CPU: %.1f%%", stats.globalCpu))
            Text("Disk free: \(Formatters.gigabytes(bytes: stats.freeDisk)) / \(Formatters.gigabytes(bytes: stats.totalDisk))")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.textMuted)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Palette.headerBg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: 1)
        }
    }
}
