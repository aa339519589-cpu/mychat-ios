import SwiftUI

struct WorkspaceContentView: View {
    let destination: WorkspaceDestination

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(kicker)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AppPalette.secondaryText)
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .padding(.top, 24)

                Text(headline)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.45)
                    .padding(.top, 8)

                Text(summary)
                    .font(.system(size: 15.5))
                    .lineSpacing(5)
                    .foregroundStyle(AppPalette.secondaryText)
                    .padding(.top, 10)

                EditorialDivider()
                    .padding(.top, 28)

                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: destination.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AppPalette.secondaryText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(emptyTitle)
                            .font(.system(size: 16, weight: .medium))
                        Text(emptyDetail)
                            .font(.system(size: 13.5))
                            .lineSpacing(4)
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)

                EditorialDivider()
            }
            .padding(.horizontal, 20)
        }
        .background(AppPalette.background)
    }

    private var kicker: String {
        switch destination {
        case .projects: return "Workspace"
        case .artifacts: return "Library"
        case .code: return "Development"
        case .settings: return ""
        }
    }

    private var headline: String {
        switch destination {
        case .projects: return "组织长期任务"
        case .artifacts: return "集中查看生成内容"
        case .code: return "在移动端跟进代码工作"
        case .settings: return ""
        }
    }

    private var summary: String {
        switch destination {
        case .projects:
            return "项目中的对话、资料与指令会保持在同一条连续工作流中。"
        case .artifacts:
            return "图片、文档与其他生成结果按时间汇集，直接进入内容本身。"
        case .code:
            return "仓库、任务与执行结果使用清晰的文本层级排列。"
        case .settings:
            return ""
        }
    }

    private var emptyTitle: String {
        switch destination {
        case .projects: return "暂无项目"
        case .artifacts: return "暂无作品"
        case .code: return "暂无代码任务"
        case .settings: return ""
        }
    }

    private var emptyDetail: String {
        switch destination {
        case .projects: return "创建或加入项目后，内容会显示在这里。"
        case .artifacts: return "对话中生成的作品会自动出现在这里。"
        case .code: return "开始代码任务后，仓库与运行状态会显示在这里。"
        case .settings: return ""
        }
    }
}
