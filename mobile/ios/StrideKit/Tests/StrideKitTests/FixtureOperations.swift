import Foundation

@testable import StrideKit

/// Calls every operation that has a shared fixture and returns the decoded body.
enum FixtureOperations {
    typealias Call = @Sendable (any StrideAPI) async throws -> any Encodable

    static let calls: [String: Call] = [
        Operations.OauthToken.id: {
            try await $0.oauthToken(
                body: .json(.init(grantType: .refreshToken, clientId: .strideIos, refreshToken: "EXAMPLE"))
            ).ok.body.json
        },
        Operations.OauthRevoke.id: {
            try await $0.oauthRevoke(body: .json(.init(token: "EXAMPLE", clientId: .strideIos))).ok.body.json
        },
        Operations.GetMe.id: { try await $0.getMe().ok.body.json },
        Operations.ListMyDevices.id: { try await $0.listMyDevices().ok.body.json },
        Operations.UpdateCurrentDevice.id: {
            try await $0.updateCurrentDevice(body: .json(.init(locale: "en"))).ok.body.json
        },
        Operations.CreateMySocketToken.id: { try await $0.createMySocketToken().created.body.json },
        Operations.GetMyNotificationSettings.id: { try await $0.getMyNotificationSettings().ok.body.json },
        Operations.UpdateMyNotificationSettings.id: {
            try await $0.updateMyNotificationSettings(body: .json(.init(mode: .every))).ok.body.json
        },
        Operations.ListMyDecisions.id: { try await $0.listMyDecisions().ok.body.json },
        Operations.ListMyReviews.id: { try await $0.listMyReviews().ok.body.json },
        Operations.GetMyReview.id: { try await $0.getMyReview(path: .init(taskId: 1)).ok.body.json },
        Operations.GetMyReviewFile.id: {
            try await $0.getMyReviewFile(path: .init(taskId: 1, index: 0)).ok.body.json
        },
        Operations.CreateMyReviewApprovalChallenge.id: {
            try await $0.createMyReviewApprovalChallenge(
                path: .init(taskId: 1),
                body: .json(.init(reviewFingerprint: "EXAMPLE"))
            ).created.body.json
        },
        Operations.ApproveMyReview.id: {
            try await $0.approveMyReview(
                path: .init(taskId: 1),
                body: .json(.init(nonce: "EXAMPLE", signature: "EXAMPLE"))
            ).ok.body.json
        },
        Operations.RequestMyReviewChanges.id: {
            try await $0.requestMyReviewChanges(
                path: .init(taskId: 1),
                body: .json(.init(notes: "EXAMPLE"))
            ).ok.body.json
        },
        Operations.ListMyBoards.id: { try await $0.listMyBoards().ok.body.json },
        Operations.GetMyBoardColumn.id: {
            try await $0.getMyBoardColumn(path: .init(id: 1, name: "Ready")).ok.body.json
        },
        Operations.PromoteMyBoardTasks.id: {
            try await $0.promoteMyBoardTasks(path: .init(id: 1), body: .json(.init(taskIds: [1]))).ok.body.json
        },
        Operations.CaptureMyTask.id: {
            try await $0.captureMyTask(body: .json(.init(boardId: 1, _type: .work, title: "EXAMPLE"))).created.body.json
        },
        Operations.GetMyTask.id: { try await $0.getMyTask(path: .init(id: 1)).ok.body.json },
        Operations.CommentOnMyTask.id: {
            try await $0.commentOnMyTask(path: .init(id: 1), body: .json(.init(content: "EXAMPLE"))).created.body.json
        },
        Operations.MoveMyTaskToBacklog.id: {
            try await $0.moveMyTaskToBacklog(path: .init(id: 1)).ok.body.json
        },
        Operations.ListMyAgents.id: { try await $0.listMyAgents().ok.body.json },
        Operations.GetMyGoalAfterGoal.id: { try await $0.getMyGoalAfterGoal(path: .init(id: 1)).ok.body.json },
        Operations.ListMyGoals.id: { try await $0.listMyGoals().ok.body.json },
        Operations.GetMyGoal.id: { try await $0.getMyGoal(path: .init(id: 1)).ok.body.json },
        Operations.ListMyTargets.id: { try await $0.listMyTargets().ok.body.json },
        Operations.GetMyTarget.id: { try await $0.getMyTarget(path: .init(id: 1)).ok.body.json }
    ]
}
