import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  canonicalXProfileURL,
  canonicalXStatusURL,
  isXProfileURL,
  MAX_X_PROFILE_CANDIDATES,
  normalizeXProfileItems,
  parseProfileCandidatesPresented,
  profileCollectFailureCopy,
  profileHandleFromURL,
  profilePresentedMessage,
  isPublicTwimgProfileImageURL,
  resolvedXProfileDisplayName,
  xProfileDisplayName,
  collectXProfileItemsInPage,
} from "../src/content/x-profile";
import validateXProfileSchema from "../src/generated/x-profile-validator.mjs";

describe("X profile URL detection", () => {
  it("accepts handle homepages and rejects home, bookmarks, and tweets", () => {
    for (const ok of [
      "https://x.com/sample_author",
      "https://www.twitter.com/Sample_Author",
    ]) {
      expect(isXProfileURL(ok)).toBe(true);
    }
    for (const no of [
      "https://x.com/home",
      "https://x.com/i/bookmarks",
      "https://x.com/sample_author/status/1234567890123",
      "https://x.com/sample_author/with_replies",
      "http://x.com/sample_author",
      "https://name:pass@x.com/sample_author",
      "https://x.com.evil.test/sample_author",
      undefined,
    ]) {
      expect(isXProfileURL(no)).toBe(false);
    }
    expect(profileHandleFromURL("https://x.com/Sample_Author")).toBe("sample_author");
    expect(MAX_X_PROFILE_CANDIDATES).toBe(100);
  });
});

describe("X profile display name", () => {
  it("strips only a trailing @handle from concatenated UserName text", () => {
    expect(xProfileDisplayName("DAN KOE@thedankoe", "thedankoe")).toBe("DAN KOE");
    expect(xProfileDisplayName("DAN KOE\n@thedankoe", "thedankoe")).toBe("DAN KOE");
    expect(xProfileDisplayName("DAN KOE (@thedankoe)", "thedankoe")).toBe("DAN KOE");
    expect(xProfileDisplayName("DAN KOE@TheDanKoe", "thedankoe")).toBe("DAN KOE");
  });

  it("keeps handle text that appears in the middle of the display name", () => {
    expect(xProfileDisplayName("thedankoe notes@thedankoe", "thedankoe")).toBe("thedankoe notes");
    expect(xProfileDisplayName("Ask @thedankoe later@thedankoe", "thedankoe")).toBe("Ask @thedankoe later");
  });

  it("does not treat @handle as a resolved display name for the native payload", () => {
    expect(resolvedXProfileDisplayName("", "sample_author")).toBeNull();
    expect(resolvedXProfileDisplayName("@sample_author", "sample_author")).toBeNull();
    expect(resolvedXProfileDisplayName("夹具作者", "sample_author")).toBe("夹具作者");
    expect(xProfileDisplayName("@sample_author", "sample_author")).toBe("@sample_author");
  });
});

describe("X profile avatar admission", () => {
  it("admits only public twimg profile_images URLs", () => {
    expect(isPublicTwimgProfileImageURL("https://pbs.twimg.com/profile_images/1/owner.jpg")).toBe(true);
    expect(isPublicTwimgProfileImageURL("https://pbs.twimg.com/media/tweet.jpg")).toBe(false);
    expect(isPublicTwimgProfileImageURL("https://abs.twimg.com/sticky/default_profile.png")).toBe(false);
    expect(isPublicTwimgProfileImageURL("https://example.test/profile_images/x.jpg")).toBe(false);
    expect(isPublicTwimgProfileImageURL("http://pbs.twimg.com/profile_images/1/owner.jpg")).toBe(false);
  });

  it("inlines parameterized owner photo extraction in the injected collect script", () => {
    const source = collectXProfileItemsInPage.toString();
    expect(source).toContain("photoPath");
    expect(source).toContain("/photo");
    expect(source).toContain("profile_images");
    expect(source).toContain("UserAvatar-Container-");
    expect(source).not.toContain('href$="/photo"');
    expect(source).not.toContain("profileName || token");
  });
});

describe("X profile candidate normalization", () => {
  it("keeps only the profile owner's status URLs", () => {
    const items = normalizeXProfileItems([
      { id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "Own" },
      { id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123" },
      { id: "9876543210987", url: "https://x.com/other/status/9876543210987" },
      { id: "not-id", url: "https://x.com/sample_author/status/123" },
    ], "sample_author");
    expect(items).toEqual([
      { id: "1234567890123", url: "https://x.com/sample_author/status/1234567890123", previewText: "Own" },
    ]);
  });
});

describe("X profile native ACK parsing", () => {
  it("accepts profileCandidatesPresented and never treats bookmarksAccepted as success", () => {
    expect(parseProfileCandidatesPresented({
      kind: "profileCandidatesPresented", version: 1, requestId: "r", acceptedCount: 4,
    })).toEqual({ acceptedCount: 4, requestId: "r" });
    expect(parseProfileCandidatesPresented({
      kind: "bookmarksAccepted", version: 1, requestId: "r", queuedCount: 4, skippedCount: 0,
    })).toBeNull();
    expect(parseProfileCandidatesPresented({
      kind: "taskAccepted", version: 1, requestId: "r", characterCount: 12,
    })).toBeNull();
  });

  it("explains native and upgrade failures without claiming login is valid", () => {
    expect(profileCollectFailureCopy("native_error")).toContain("不代表通道已通");
    expect(profileCollectFailureCopy("upgrade_app")).toContain("未保存");
    expect(profileCollectFailureCopy("login")).toContain("不会读取 Cookie");
    expect(profilePresentedMessage(3)).toContain("尚未入库");
  });
});

describe("X profile contract schema", () => {
  it("accepts a canonical request and ACK, and rejects cookies or bookmarks ACK", () => {
    const request = {
      kind: "xProfileCandidates",
      version: 1,
      requestId: "req-1",
      profileURL: canonicalXProfileURL("sample_author"),
      authorID: "sample_author",
      items: [{ id: "1234567890123", url: canonicalXStatusURL("sample_author", "1234567890123"), previewText: "Hello" }],
    };
    expect(validateXProfileSchema(request)).toBe(true);
    expect(validateXProfileSchema({
      kind: "profileCandidatesPresented", version: 1, requestId: "req-1", acceptedCount: 1,
    })).toBe(true);
    expect(validateXProfileSchema({ ...request, cookie: "auth_token=secret" })).toBe(false);
    expect(validateXProfileSchema({
      kind: "bookmarksAccepted", version: 1, requestId: "req-1", queuedCount: 1, skippedCount: 0,
    })).toBe(false);
    expect(validateXProfileSchema({
      ...request,
      profileAvatarURL: "https://pbs.twimg.com/profile_images/1/owner.jpg",
    })).toBe(true);
    expect(validateXProfileSchema({
      ...request,
      profileAvatarURL: "https://pbs.twimg.com/media/tweet.jpg",
    })).toBe(false);
  });

  it("matches the bundled language-neutral schema file", () => {
    const schema = JSON.parse(readFileSync(new URL("../../../contracts/x-profile-candidates-v1.schema.json", import.meta.url), "utf8")) as { $id: string };
    expect(schema.$id).toContain("x-profile-candidates-v1");
  });
});
