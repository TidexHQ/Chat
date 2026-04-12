import Testing

@testable import ExyteChat

struct TableUpdateAnimationPolicyTest {
    @Test("Status-only refreshes do not animate table updates")
    func doesNotAnimateWhenIDsAreUnchanged() {
        #expect(
            TableUpdateAnimationPolicy.shouldAnimate(
                transactionAnimated: true,
                needsExternalScroll: false,
                previousIDs: ["message-1"],
                newIDs: ["message-1"]
            ) == false
        )
    }

    @Test("Real inserts still animate when scrolling is not forced")
    func animatesWhenIDsChange() {
        #expect(
            TableUpdateAnimationPolicy.shouldAnimate(
                transactionAnimated: true,
                needsExternalScroll: false,
                previousIDs: ["message-1"],
                newIDs: ["message-1", "message-2"]
            ) == true
        )
    }
}
