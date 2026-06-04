import AppKit
import SwiftUI
import usageBarCore
import usageBarProviders

/// Settings 面板(右键菜单 → 偏好设置...)
///
/// 形态:family 用虚线圆角框包起来,标题压在虚线边上(类似 HTML fieldset);
/// 独立 provider(Codex/悟空)不框,直接平铺。无父级 Toggle — 用户要"关 family 整组"
/// 自己把子项各自关掉即可(UI 视觉用虚线框提示同组关联)。
struct SettingsView: View {
    @ObservedObject var settings: ProviderVisibilitySettings

    private let familyDisplayName: [String: String] = [
        "claude": "Claude Code",
    ]

    /// GitHub mark(模板图,跟随主题/链接色)
    private static let githubIcon: NSImage? = {
        guard let img = BundleIconLoader.load(name: "github", ext: "svg") else { return nil }
        img.isTemplate = true
        return img
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedSections, id: \.id) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .medium))
            Text("usageBar 偏好设置")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text("提示:勾选状态实时生效,弹层会自动刷新。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: {
                if let url = URL(string: "https://github.com/ChanningYuan/usageBar") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    if let img = Self.githubIcon {
                        Image(nsImage: img)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                    }
                    Text("在 GitHub 点个 Star")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.link)
            .help("在 GitHub 上点个 Star ⭐")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 数据分组

    /// 一个"区块":要么是 family(虚线框 + 多子项),要么是 standalone(单 toggle 平铺)
    private struct SettingsSection: Identifiable {
        let id: String
        let title: String
        let family: String?
        let providers: [any UsageProvider]
    }

    private var groupedSections: [SettingsSection] {
        let all = ProviderRegistry.all
        var result: [SettingsSection] = []
        var seenFamilies: Set<String> = []

        for p in all {
            if let fam = p.family {
                if seenFamilies.contains(fam) { continue }
                seenFamilies.insert(fam)
                let famProviders = all.filter { $0.family == fam }
                result.append(SettingsSection(
                    id: "fam:\(fam)",
                    title: familyDisplayName[fam] ?? fam,
                    family: fam,
                    providers: famProviders
                ))
            } else {
                result.append(SettingsSection(
                    id: "prov:\(p.id)",
                    title: p.displayName,
                    family: nil,
                    providers: [p]
                ))
            }
        }
        return result
    }

    // MARK: - Section View

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        if section.family != nil {
            familyBox(title: section.title, providers: section.providers)
        } else if let provider = section.providers.first {
            standaloneRow(provider: provider)
        }
    }

    /// family 块:虚线圆角框 + 压边标题
    private func familyBox(title: String, providers: [any UsageProvider]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(providers, id: \.id) { p in
                providerToggleRow(p)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .overlay(alignment: .topLeading) {
            // 压在虚线边上的组名标题(背景色覆盖虚线达到 fieldset 视觉)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: 12, y: -7)
        }
    }

    /// 单个 provider 的 Toggle 行(虚线框内 / 独立平铺通用)
    private func providerToggleRow(_ p: any UsageProvider) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.isProviderToggleOn(p.id) },
                set: { settings.setProvider(p.id, enabled: $0) }
            )) {
                Text(p.displayName)
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Spacer()
        }
    }

    /// 独立 provider:单行 Toggle(Codex / 悟空 / WorkBuddy / Cursor)
    /// 字号/weight 跟虚线框内子项完全一致(size 12 regular),只是水平 padding 跟框内对齐
    private func standaloneRow(provider: any UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { settings.isProviderToggleOn(provider.id) },
                    set: { settings.setProvider(provider.id, enabled: $0) }
                )) {
                    Text(provider.displayName)
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
            }

            // Cursor 专属:隐私提示(它是唯一联网的 provider)
            if provider.id == "cursor" {
                Text("Cursor 真实用量只在服务端，需联网获取：勾选后每次刷新会读取本机 Cursor 登录凭证并请求 cursor.com。不想联网就取消勾选。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
