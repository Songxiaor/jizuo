import { describe, expect, it } from "vitest";
import { validateXProfileCandidatesMessage } from "../src/x-profile-candidates.js";

const request = {
  kind: "xProfileCandidates",
  version: 1,
  requestId: "req-1",
  profileURL: "https://x.com/sample_author",
  authorID: "sample_author",
  items: [{ id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "Hello" }],
} as const;

describe("x-profile-candidates contract", () => {
  it("accepts request and presented ACK", () => {
    expect(validateXProfileCandidatesMessage(request).ok).toBe(true);
    expect(validateXProfileCandidatesMessage({
      kind: "profileCandidatesPresented",
      version: 1,
      requestId: "req-1",
      acceptedCount: 1,
    }).ok).toBe(true);
  });

  it("rejects cookies, reserved home, oversize lists, and bookmarks ACK", () => {
    expect(validateXProfileCandidatesMessage({ ...request, cookie: "secret" }).ok).toBe(false);
    expect(validateXProfileCandidatesMessage({ ...request, authorID: "home", profileURL: "https://x.com/home" }).ok).toBe(false);
    expect(validateXProfileCandidatesMessage({
      kind: "bookmarksAccepted", version: 1, requestId: "req-1", queuedCount: 1, skippedCount: 0,
    }).ok).toBe(false);
    const flood = Array.from({ length: 101 }, (_, index) => ({
      id: String(1_000_000_000 + index),
      url: `https://x.com/sample_author/status/${1_000_000_000 + index}`,
    }));
    expect(validateXProfileCandidatesMessage({ ...request, items: flood }).ok).toBe(false);
  });

  it("accepts optional public twimg profile avatar and rejects tweet media", () => {
    expect(validateXProfileCandidatesMessage({
      ...request,
      profileAvatarURL: "https://pbs.twimg.com/profile_images/1/owner.jpg",
    }).ok).toBe(true);
    expect(validateXProfileCandidatesMessage({
      ...request,
      profileAvatarURL: "https://pbs.twimg.com/media/tweet.jpg",
    }).ok).toBe(false);
  });
});
