import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { extractDouyinSingleItemMetaInPage } from "../src/content/extract";

afterEach(() => {
  vi.unstubAllGlobals();
});

type VideoFixture = {
  source: string;
  mimeType?: string | null;
  paused?: boolean;
  readyState?: number;
  rect: { left: number; top: number; right: number; bottom: number };
  interactionChild?: object;
  boundAwemeId?: string;
  identityHref?: string;
  stats?: Partial<Record<"likes" | "comments" | "shares" | "collects", string>>;
  siblingStats?: Partial<Record<"likes" | "comments" | "shares" | "collects", string>>;
  publishedAt?: string;
};

function modalDocument(
  videoFixtures: VideoFixture[],
  activeElement: object | null = null,
  documentStats: VideoFixture["stats"] = undefined,
): Document {
  const videos = videoFixtures.map((fixture) => {
    const statSelectors: Record<string, string | undefined> = {
      "[data-e2e='feed-video-like-count']": fixture.stats?.likes,
      "[data-e2e='feed-video-comment-count']": fixture.stats?.comments,
      "[data-e2e='feed-video-share-count']": fixture.stats?.shares,
      "[data-e2e='feed-video-favorite-count']": fixture.stats?.collects,
    };
    const identityContainer = fixture.boundAwemeId || fixture.identityHref
      ? {
          parentElement: null as unknown,
          getAttribute: (name: string) => {
            if (name === "data-aweme-id") return fixture.boundAwemeId ?? null;
            if (name === "href") return fixture.identityHref ?? null;
            return null;
          },
          querySelector: (selector: string) => {
            const value = statSelectors[selector];
            return value ? { textContent: value } : null;
          },
          querySelectorAll: () => [],
        }
      : null;
    const siblingStats = fixture.siblingStats;
    const itemScope = siblingStats && identityContainer
      ? {
          parentElement: null,
          getAttribute: () => null,
          querySelector: (selector: string) => {
            if (selector === "time[datetime]" && fixture.publishedAt) return { getAttribute: () => fixture.publishedAt };
            const values: Record<string, string | undefined> = {
              "[data-e2e='feed-video-like-count']": siblingStats.likes,
              "[data-e2e='feed-video-comment-count']": siblingStats.comments,
              "[data-e2e='feed-video-share-count']": siblingStats.shares,
              "[data-e2e='feed-video-favorite-count']": siblingStats.collects,
            };
            const value = values[selector];
            return value ? { textContent: value } : null;
          },
          querySelectorAll: () => [identityContainer],
        }
      : null;
    if (identityContainer && itemScope) identityContainer.parentElement = itemScope;
    return {
      currentSrc: fixture.source,
      src: "",
      paused: fixture.paused ?? true,
      ended: false,
      readyState: fixture.readyState ?? 4,
      mediaKeys: null,
      duration: 18,
      poster: "",
      parentElement: identityContainer,
      querySelector: () => null,
      getAttribute: (name: string) => name === "type" ? (fixture.mimeType === undefined ? "video/mp4" : fixture.mimeType) : null,
      contains: (target: object | null) => target === fixture.interactionChild,
      getBoundingClientRect: () => fixture.rect,
    };
  });
  const meta = (content: string) => ({
    getAttribute: (name: string) => name === "content" ? content : null,
  });
  return {
    location: { href: "https://example.test/jingxuan?modal_id=7655224917603994914" },
    title: "Modal fixture",
    defaultView: { innerWidth: 1000, innerHeight: 800 },
    activeElement,
    querySelector(selector: string) {
      if (selector === "meta[property='og:title']") return meta("同一快照标题");
      if (selector === "meta[property='og:description']") return meta("同一快照正文");
      if (selector === "meta[name='author']") return meta("Fixture Author");
      const documentStatSelectors: Record<string, string | undefined> = {
        "[data-e2e='feed-video-like-count']": documentStats?.likes,
        "[data-e2e='feed-video-comment-count']": documentStats?.comments,
        "[data-e2e='feed-video-share-count']": documentStats?.shares,
        "[data-e2e='feed-video-favorite-count']": documentStats?.collects,
      };
      const value = documentStatSelectors[selector];
      if (value) return { textContent: value };
      return null;
    },
    querySelectorAll: (selector: string) => selector === "video" ? videos : [],
  } as unknown as Document;
}

function canonicalDedicatedDocument(options: {
  id?: string;
  url?: string;
  secondVideoRect?: { left: number; top: number; right: number; bottom: number };
  identity?: string;
  outerScenario?: "identity" | "secondVideo" | "identityLimit";
  publishedAt?: string;
  stats?: VideoFixture["stats"];
  structuredStats?: Array<{ value: string; signal?: string }>;
} = {}): Document {
  const id = options.id ?? "7655224917603994914";
  const rect = { left: 0, top: 0, right: 900, bottom: 700 };
  const makeVideo = (videoRect: typeof rect) => ({
    currentSrc: "https://media.example.test/current.mp4", src: "", paused: true, ended: false, readyState: 4, mediaKeys: null,
    currentTime: 0, parentElement: null as unknown, tagName: "VIDEO",
    querySelector: () => null, querySelectorAll: () => [], getAttribute: (name: string) => name === "type" ? "video/mp4" : null,
    contains: () => false, getBoundingClientRect: () => videoRect,
  });
  const primary = makeVideo(rect);
  const playerVideos = [primary, ...(options.secondVideoRect ? [makeVideo(options.secondVideoRect)] : [])];
  const identityNode = options.identity
    ? { getAttribute: (name: string) => name === "data-aweme-id" ? options.identity ?? null : null }
    : null;
  const countSelectors: Record<string, string | undefined> = {
    "[data-e2e='feed-video-like-count']": options.stats?.likes,
    "[data-e2e='feed-video-comment-count']": options.stats?.comments,
    "[data-e2e='feed-video-share-count']": options.stats?.shares,
    "[data-e2e='feed-video-favorite-count']": options.stats?.collects,
  };
  const structuredStatNodes = (options.structuredStats ?? []).map(({ value, signal }) => ({
    textContent: value,
    parentElement: null,
    previousElementSibling: null,
    nextElementSibling: null,
    getAttribute: (name: string) => name === "class" ? signal ?? null : null,
  }));
  const player = {
    parentElement: null as unknown,
    tagName: "DIV",
    // A real identified card carries the id on the container itself. Returning
    // null here left `activeVideoContainer` unresolved, so `safeItemScopes` was
    // always empty and any scope-restricted behaviour could not be exercised.
    getAttribute: (name: string) =>
      name === "data-aweme-id" ? options.identity ?? null : null,
    querySelector: (selector: string) => {
      if (selector === "time[datetime]" && options.publishedAt) return { getAttribute: () => options.publishedAt };
      const count = countSelectors[selector];
      return count === undefined ? null : { textContent: count };
    },
    querySelectorAll: (selector: string) => {
      if (selector === "video") return playerVideos;
      if (selector === "[aria-label]") return [];
      if (selector === "*") return structuredStatNodes;
      if (selector.includes("data-aweme-id")) return identityNode ? [identityNode] : [];
      return [];
    },
  };
  primary.parentElement = player;
  for (const video of playerVideos.slice(1)) video.parentElement = player;
  const outerPreview = options.outerScenario === "secondVideo"
    ? makeVideo({ left: 920, top: 0, right: 1_020, bottom: 100 })
    : null;
  const outerIdentities = options.outerScenario === "identityLimit"
    ? Array.from({ length: 121 }, () => ({ getAttribute: (name: string) => name === "data-aweme-id" ? id : null }))
    : [];
  const outer = options.outerScenario ? {
    parentElement: null,
    tagName: "DIV",
    getAttribute: (name: string) => name === "data-aweme-id" && options.outerScenario === "identity" ? "7123456789012345678" : null,
    querySelector: () => null,
    querySelectorAll: (selector: string) => {
      if (selector === "video") return outerPreview ? [primary, outerPreview] : [primary];
      if (selector.includes("data-aweme-id")) return outerIdentities;
      return [];
    },
  } : null;
  if (outer) {
    player.parentElement = outer;
    if (outerPreview) outerPreview.parentElement = outer;
  }
  const videos = [...playerVideos, ...(outerPreview ? [outerPreview] : [])];
  return {
    location: { href: options.url ?? `https://www.douyin.com/video/${id}` }, title: "Canonical fixture", defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
    querySelector: () => null,
    querySelectorAll: (selector: string) => selector === "video" ? videos : [],
  } as unknown as Document;
}

function scriptDocument(scripts: Record<string, { textContent: string; tagName?: string }>): Document {
  return {
    getElementById: (name: string) => scripts[name]
      ? { tagName: scripts[name]!.tagName ?? "SCRIPT", textContent: scripts[name]!.textContent }
      : null,
  } as unknown as Document;
}

describe("background douyin item identity lock", () => {
  it("locks modal A before ranking, even when explicitly identified feed B is playing", () => {
    vi.stubGlobal("document", modalDocument([
      {
        source: "https://media.example.test/feed-b.mp4",
        paused: false,
        boundAwemeId: "7123456789012345678",
        rect: { left: 0, top: 0, right: 900, bottom: 700 },
      },
      {
        source: "https://media.example.test/aweme/v1/play?video_id=modal-a",
        mimeType: null,
        identityHref: "https://example.test/video/7655224917603994914",
        rect: { left: 20, top: 20, right: 220, bottom: 120 },
      },
    ]));

    expect(extractDouyinSingleItemMetaInPage()?.mediaDescriptor).toMatchObject({
      kind: "directFile",
      ephemeralPlaybackURL: "https://media.example.test/aweme/v1/play?video_id=modal-a",
      candidateCount: 2,
      selectionReason: "singleCandidate",
      playbackState: "paused",
    });
  });

  it("extracts engagement stats from the active video's identity container", () => {
    vi.stubGlobal("document", modalDocument([
      {
        source: "https://media.example.test/current.mp4",
        boundAwemeId: "7655224917603994914",
        rect: { left: 20, top: 20, right: 900, bottom: 700 },
        stats: { likes: "1.2万", comments: "345", shares: "67", collects: "890" },
      },
    ]));

    expect(extractDouyinSingleItemMetaInPage()?.stats).toEqual({
      likes: "1.2万",
      comments: "345",
      shares: "67",
      collects: "890",
    });
  });

  it("reaches a sibling action bar only through a common scope locked to the current aweme", () => {
    vi.stubGlobal("document", modalDocument([
      {
        source: "https://media.example.test/current.mp4",
        boundAwemeId: "7655224917603994914",
        rect: { left: 20, top: 20, right: 900, bottom: 700 },
        siblingStats: { likes: "0", comments: "2", shares: "3", collects: "4" },
        publishedAt: "2026-07-20T01:02:03Z",
      },
    ]));

    expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "0", comments: "2", shares: "3", collects: "4" },
    });
  });

  it("keeps the nickname without the screen-reader badge label beside it", () => {
    const id = "7655224917603994914";
    const video = {
      currentSrc: "https://media.example.test/a.mp4", src: "", paused: true, ended: false, readyState: 4, mediaKeys: null, currentTime: 0,
      parentElement: null as unknown, tagName: "VIDEO", querySelector: () => null, querySelectorAll: () => [],
      getAttribute: (name: string) => name === "type" ? "video/mp4" : null, contains: () => false,
      getBoundingClientRect: () => ({ left: 0, top: 0, right: 900, bottom: 700 }),
    };
    const nickname = {
      textContent: "王自如AI认证徽章",
      childNodes: [
        { nodeType: 3, textContent: "王自如AI" },
        { nodeType: 1, textContent: "认证徽章" },
      ],
    };
    const player = {
      parentElement: null, tagName: "DIV",
      getAttribute: (name: string) => name === "data-aweme-id" ? id : null,
      querySelector: (selector: string) => selector.includes("nickname") ? nickname : null,
      querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    };
    video.parentElement = player;
    vi.stubGlobal("document", {
      location: { href: `https://www.douyin.com/video/${id}` }, title: "fixture",
      defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
      querySelector: () => null, querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    } as unknown as Document);

    expect(extractDouyinSingleItemMetaInPage()?.author).toBe("王自如AI");
  });

  it("reads canonical identity-less sibling date and stats only from its dominant visible player", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "0", comments: "2", shares: "3", collects: "4" },
    }));

    expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
      author: null,
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "0", comments: "2", shares: "3", collects: "4" },
      metadataDiagnostic: {
        route: { eligible: true, rejectCode: "none" },
        video: { dominantVideoCount: 1, rejectCode: "none" },
        scopes: { rejectCode: "dominant_video_proof" },
        dom: { publishedSelectorHit: true, statSelectorHitMask: 15, statAcceptedCount: 4 },
      },
    });
  });

  it("uses labeled numeric fallback stats only inside the safe player scope", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      identity: "7655224917603994914",
      structuredStats: [
        { value: "1.2万", signal: "action-digg" },
        { value: "3", signal: "action-comment" },
        { value: "4", signal: "action-share" },
        { value: "5", signal: "action-collect" },
      ],
    }));

    expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
      stats: { likes: "1.2万", comments: "3", shares: "4", collects: "5" },
      metadataDiagnostic: { dom: { statSelectorHitMask: 15, statAcceptedCount: 4 } },
    });
  });

  it("does not apply structured fallback to an identity-less dedicated metadata scope", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      structuredStats: [{ value: "1", signal: "action-digg" }],
    }));

    expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
      // Dedicated metadata starts at the player container, never the bare
      // <video>. This accepted scope still may not feed structured fallback.
      metadataDiagnostic: { scopes: { dedicatedCount: 1 }, dom: { statSelectorHitMask: 0, statAcceptedCount: 0 } },
    });
    expect(extractDouyinSingleItemMetaInPage()?.stats).toBeUndefined();
  });

  it("abandons a safe scope when structured numeric candidates exceed 200", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      identity: "7655224917603994914",
      structuredStats: [
        { value: "1", signal: "action-digg" },
        ...Array.from({ length: 200 }, () => ({ value: "2" })),
      ],
    }));

    expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
      metadataDiagnostic: { dom: { statSelectorHitMask: 0, statAcceptedCount: 0 } },
    });
    expect(extractDouyinSingleItemMetaInPage()?.stats).toBeUndefined();
  });

  it("does not treat an unlabeled number as a Douyin engagement stat", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      structuredStats: [{ value: "999" }],
    }));

    expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
      metadataDiagnostic: { dom: { statSelectorHitMask: 0, statAcceptedCount: 0 } },
    });
    expect(extractDouyinSingleItemMetaInPage()?.stats).toBeUndefined();
  });

  it("uses the same dominant-video proof for a locked feed/modal URL", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      url: "https://www.douyin.com/jingxuan?modal_id=7655224917603994914",
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "1", comments: "2", shares: "3", collects: "4" },
    }));

    const result = extractDouyinSingleItemMetaInPage();
    expect(result).toMatchObject({
      awemeId: "7655224917603994914",
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "1", comments: "2", shares: "3", collects: "4" },
      metadataDiagnostic: {
        route: { eligible: true, rejectCode: "none" },
        video: { rejectCode: "none" },
        scopes: { rejectCode: "dominant_video_proof" },
      },
    });
  });

  it("fails closed when a feed/modal route exposes a second recognized item ID", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      url: "https://www.douyin.com/jingxuan?modal_id=7655224917603994914&aweme_id=7123456789012345678",
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "999" },
    }));

    const result = extractDouyinSingleItemMetaInPage();
    expect(result?.metadataDiagnostic?.route).toEqual({ eligible: false, rejectCode: "non_canonical_route" });
    expect(result?.publishedAt).toBeUndefined();
    expect(result?.stats).toBeUndefined();
  });

  it("rejects identity-less metadata when two visible videos are too close in area", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      secondVideoRect: { left: 0, top: 0, right: 700, bottom: 650 },
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "999" },
    }));

    const result = extractDouyinSingleItemMetaInPage();
    expect(result?.publishedAt).toBeUndefined();
    expect(result?.stats).toBeUndefined();
    expect(result?.metadataDiagnostic?.video.rejectCode).toBe("not_uniquely_dominant");
  });

  it("rejects a small second visible video inside an otherwise globally dominant feed player", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      url: "https://www.douyin.com/jingxuan?modal_id=7655224917603994914",
      secondVideoRect: { left: 920, top: 0, right: 1_020, bottom: 100 },
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "999" },
    }));

    const result = extractDouyinSingleItemMetaInPage();
    expect(result?.metadataDiagnostic?.video.rejectCode).toBe("none");
    expect(result?.metadataDiagnostic?.scopes.rejectCode).toBe("not_dedicated");
    expect(result?.publishedAt).toBeUndefined();
    expect(result?.stats).toBeUndefined();
  });

  it.each(["identity", "secondVideo", "identityLimit"] as const)(
    "keeps the safe identity-less player scope when a wider %s wrapper fails",
    (outerScenario) => {
      vi.stubGlobal("document", canonicalDedicatedDocument({
        url: "https://www.douyin.com/jingxuan?modal_id=7655224917603994914",
        outerScenario,
        publishedAt: "2026-07-20T01:02:03Z",
        stats: { likes: "1", comments: "2", shares: "3", collects: "4" },
      }));

      expect(extractDouyinSingleItemMetaInPage()).toMatchObject({
        publishedAt: "2026-07-20T01:02:03Z",
        stats: { likes: "1", comments: "2", shares: "3", collects: "4" },
        metadataDiagnostic: { scopes: { dedicatedCount: 1, rejectCode: "dominant_video_proof" } },
      });
    },
  );

  it("rejects the dedicated fallback when its bounded player scope identifies another aweme", () => {
    vi.stubGlobal("document", canonicalDedicatedDocument({
      identity: "7123456789012345678",
      publishedAt: "2026-07-20T01:02:03Z",
      stats: { likes: "999" },
    }));

    const result = extractDouyinSingleItemMetaInPage();
    expect(result?.author).toBeNull();
    expect(result?.publishedAt).toBeUndefined();
    expect(result?.stats).toBeUndefined();
    expect(result?.metadataDiagnostic?.scopes).toMatchObject({ safeCount: 0, dedicatedCount: 0, rejectCode: "identity_conflict" });
  });

  it("keeps the proven-safe inner scope when a neighbouring card owns the ancestor", () => {
    const id = "7655224917603994914";
    const other = "7123456789012345678";
    const video = {
      currentSrc: "https://media.example.test/a.mp4", src: "", paused: true, ended: false, readyState: 4, mediaKeys: null, currentTime: 0,
      parentElement: null as unknown, tagName: "VIDEO", querySelector: () => null, querySelectorAll: () => [],
      getAttribute: (name: string) => name === "type" ? "video/mp4" : null, contains: () => false,
      getBoundingClientRect: () => ({ left: 0, top: 0, right: 900, bottom: 700 }),
    };
    // The card that actually owns the visible player: only ever names `id`.
    const card = {
      parentElement: null as unknown, tagName: "DIV",
      getAttribute: (name: string) => name === "data-aweme-id" ? id : null,
      querySelector: (selector: string) => {
        if (selector === "time[datetime]") return { getAttribute: () => "2026-07-20T01:02:03Z" };
        if (selector === "[data-e2e='feed-video-like-count']") return { textContent: "4966" };
        if (selector === "[data-e2e='feed-video-comment-count']") return { textContent: "143" };
        return null;
      },
      querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    };
    // A feed wrapper that also contains the *next* card. Climbing into it used
    // to discard `card` entirely, which emptied safeItemScopes.
    const feed = {
      parentElement: null, tagName: "DIV",
      getAttribute: (name: string) => name === "data-aweme-id" ? other : null,
      querySelector: () => null,
      querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    };
    video.parentElement = card;
    card.parentElement = feed;
    vi.stubGlobal("document", {
      location: { href: `https://www.douyin.com/jingxuan?modal_id=${id}` }, title: "fixture",
      defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
      querySelector: () => null, querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    } as unknown as Document);

    const result = extractDouyinSingleItemMetaInPage();
    // The owning card names the locked aweme, so the climb stops there and the
    // neighbour on the ancestor never gets a chance to contaminate the scope.
    expect(result?.metadataDiagnostic?.scopes.safeCount).toBeGreaterThan(0);
    expect(result?.publishedAt).toBe("2026-07-20T01:02:03Z");
    expect(result?.stats).toMatchObject({ likes: "4966", comments: "143" });
    // The neighbour's identity must never become the captured item.
    expect(result?.awemeId).toBe(id);
  });

  it("rejects a shared ancestor that hides B only in note and item_id links", () => {
    const id = "7655224917603994914";
    const other = "7123456789012345678";
    const video = {
      currentSrc: "https://media.example.test/a.mp4", src: "", paused: true, ended: false, readyState: 4, mediaKeys: null, currentTime: 0,
      parentElement: null as unknown, tagName: "VIDEO", querySelector: () => null, querySelectorAll: () => [],
      getAttribute: (name: string) => name === "type" ? "video/mp4" : null, contains: () => false,
      getBoundingClientRect: () => ({ left: 0, top: 0, right: 900, bottom: 700 }),
    };
    const noteB = { getAttribute: (name: string) => name === "href" ? `/note/${other}` : null };
    const itemB = { getAttribute: (name: string) => name === "href" ? `?item_id=${other}` : null };
    const player = {
      parentElement: null as unknown, tagName: "DIV", getAttribute: () => null,
      querySelector: (selector: string) => selector.includes("video-desc") ? { textContent: "A 的描述" } : null,
      querySelectorAll: (selector: string) => selector === "video" ? [video] : selector === "[aria-label]" ? [] : [],
    };
    const shared = {
      parentElement: null, tagName: "DIV", getAttribute: () => null,
      querySelector: (selector: string) => {
        if (selector.includes("nickname")) return { textContent: "B 作者 999" };
        if (selector === "time[datetime]") return { getAttribute: () => "2099-01-01T00:00:00Z" };
        if (selector === "[data-e2e='feed-video-like-count']") return { textContent: "999" };
        return null;
      },
      querySelectorAll: (selector: string) => {
        if (selector === "video") return [video];
        if (selector === "[aria-label]") return [];
        if (selector.includes("/note/") && selector.includes("item_id=")) return [noteB, itemB];
        return [];
      },
    };
    video.parentElement = player;
    player.parentElement = shared;
    vi.stubGlobal("document", {
      location: { href: `https://www.douyin.com/video/${id}` }, title: "fixture", defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
      querySelector: () => null, querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    } as unknown as Document);

    const result = extractDouyinSingleItemMetaInPage();
    expect(result?.author).toBeNull();
    expect(result?.publishedAt).toBeUndefined();
    expect(result?.stats).toBeUndefined();
  });

  it("does not materialize more than 1000 video nodes for the dedicated fallback", () => {
    const primary = {
      currentSrc: "https://media.example.test/a.mp4", src: "", paused: true, ended: false, readyState: 4, mediaKeys: null, currentTime: 0,
      parentElement: null as unknown, tagName: "VIDEO", querySelector: () => null, querySelectorAll: () => [],
      getAttribute: (name: string) => name === "type" ? "video/mp4" : null, contains: () => false,
      getBoundingClientRect: () => ({ left: 0, top: 0, right: 900, bottom: 700 }),
    };
    const player = {
      parentElement: null, tagName: "DIV", getAttribute: () => null,
      querySelector: () => null, querySelectorAll: (selector: string) => selector === "video" ? [primary] : [],
    };
    primary.parentElement = player;
    let videoQueries = 0;
    const tooMany = { length: 1001 } as unknown as NodeListOf<HTMLVideoElement>;
    vi.stubGlobal("document", {
      location: { href: "https://www.douyin.com/video/7655224917603994914" }, title: "fixture", defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
      querySelector: () => null,
      querySelectorAll: (selector: string) => {
        if (selector !== "video") return [];
        videoQueries += 1;
        return videoQueries === 2 ? tooMany : [primary];
      },
    } as unknown as Document);

    expect(extractDouyinSingleItemMetaInPage()?.stats).toBeUndefined();
  });

  it("rejects an over-limit common ancestor instead of trusting its first 120 identities", () => {
    const currentID = "7655224917603994914";
    const otherID = "7123456789012345678";
    const identity = (id: string) => ({ getAttribute: (name: string) => name === "data-aweme-id" ? id : null });
    const activeScope = {
      parentElement: null as unknown,
      getAttribute: (name: string) => name === "data-aweme-id" ? currentID : null,
      querySelector: () => null,
      querySelectorAll: () => [],
    };
    const broadScope = {
      parentElement: null,
      getAttribute: () => null,
      querySelector: (selector: string) => selector === "[data-e2e='feed-video-like-count']" ? { textContent: "999" } : null,
      querySelectorAll: () => [...Array.from({ length: 120 }, () => identity(currentID)), identity(otherID)],
    };
    activeScope.parentElement = broadScope;
    const video = {
      currentSrc: "https://media.example.test/current.mp4", src: "", paused: true, ended: false, readyState: 4, mediaKeys: null,
      parentElement: activeScope, querySelector: () => null, getAttribute: (name: string) => name === "type" ? "video/mp4" : null,
      contains: () => false, getBoundingClientRect: () => ({ left: 0, top: 0, right: 900, bottom: 700 }),
    };
    vi.stubGlobal("document", {
      location: { href: `https://www.douyin.com/video/${currentID}` }, title: "fixture", defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
      querySelector: () => null, querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    } as unknown as Document);

    expect(extractDouyinSingleItemMetaInPage()?.stats).toBeUndefined();
  });

  it("never fills author from document-wide metadata when the visible player is explicitly another aweme", () => {
    const currentID = "7655224917603994914";
    const otherID = "7123456789012345678";
    const otherScope = {
      parentElement: null,
      getAttribute: (name: string) => name === "data-aweme-id" ? otherID : null,
      querySelector: (selector: string) => selector.includes("video-desc") ? { textContent: "B 的描述" } : null,
      querySelectorAll: () => [],
    };
    const video = {
      currentSrc: "https://media.example.test/b.mp4", src: "", paused: false, ended: false, readyState: 4, mediaKeys: null,
      parentElement: otherScope, querySelector: () => null, getAttribute: (name: string) => name === "type" ? "video/mp4" : null,
      contains: () => false, getBoundingClientRect: () => ({ left: 0, top: 0, right: 900, bottom: 700 }),
    };
    vi.stubGlobal("document", {
      location: { href: `https://www.douyin.com/video/${currentID}` }, title: "fixture", defaultView: { innerWidth: 1_000, innerHeight: 800 }, activeElement: null,
      querySelector: (selector: string) => {
        if (selector === "meta[name='author']") return { getAttribute: () => "B 的 meta 作者" };
        if (selector === "[data-e2e='user-info']") return { textContent: "B 的页面作者" };
        return null;
      },
      querySelectorAll: (selector: string) => selector === "video" ? [video] : [],
    } as unknown as Document);

    expect(extractDouyinSingleItemMetaInPage()?.author).toBeNull();
  });

  it("does not fill missing active-video stats from document-wide counters", () => {
    vi.stubGlobal("document", modalDocument(
      [
        {
          source: "https://media.example.test/current.mp4",
          boundAwemeId: "7655224917603994914",
          rect: { left: 20, top: 20, right: 900, bottom: 700 },
          stats: { likes: "12" },
        },
      ],
      null,
      { comments: "999", shares: "999", collects: "999" },
    ));

    expect(extractDouyinSingleItemMetaInPage()?.stats).toEqual({ likes: "12" });
  });

  it("keeps engagement stats scoped to the active video when another card is present", () => {
    vi.stubGlobal("document", modalDocument([
      {
        source: "https://media.example.test/current.mp4",
        paused: false,
        boundAwemeId: "7655224917603994914",
        rect: { left: 20, top: 20, right: 900, bottom: 700 },
        stats: { likes: "11", comments: "22", shares: "33", collects: "44" },
      },
      {
        source: "https://media.example.test/other.mp4",
        boundAwemeId: "7123456789012345678",
        rect: { left: 0, top: 0, right: 100, bottom: 100 },
        stats: { likes: "999", comments: "999", shares: "999", collects: "999" },
      },
    ]));

    expect(extractDouyinSingleItemMetaInPage()?.stats).toEqual({
      likes: "11",
      comments: "22",
      shares: "33",
      collects: "44",
    });
  });

  it("merges only defined SSR engagement fields over scoped DOM values", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const {
      extractDouyinStatsFromInitialStateInMainWorld,
      mergeDefinedDouyinStats,
    } = await import("../src/entrypoints/background");
    expect(extractDouyinStatsFromInitialStateInMainWorld.toString()).not.toContain("mergeDefinedDouyinStats");
    expect(mergeDefinedDouyinStats(
      { likes: "10", comments: "20", shares: "30", collects: "40" },
      { likes: "100" },
    )).toEqual({ likes: "100", comments: "20", shares: "30", collects: "40" });
  });

  it("finds nested exact SSR metadata, preserves real zero, and omits wrong or invalid values", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.stubGlobal("__INITIAL_STATE__", {
      deeply: { nested: { item: {
        aweme_id: "7655224917603994914",
        author: { nickname: "SSR 作者" },
        create_time: 1_784_505_600,
        statistics: { digg_count: 0, comment_count: "7", share_count: "bad", collect_count: -1 },
      } } },
      wrong: { aweme_id: "7123456789012345678", author: { nickname: "不应串入" }, create_time: "invalid", statistics: { digg_count: 999 } },
    });
    const {
      extractDouyinMetadataFromInitialStateInMainWorld,
      extractDouyinMetadataWithDiagnosticInMainWorld,
    } = await import("../src/entrypoints/background");

    expect(extractDouyinMetadataFromInitialStateInMainWorld("7655224917603994914")).toEqual({
      author: "SSR 作者",
      publishedAt: "2026-07-20T00:00:00.000Z",
      stats: { likes: "0", comments: "7" },
    });
    expect(extractDouyinMetadataFromInitialStateInMainWorld("7123456789012345678")).toEqual({ author: "不应串入", stats: { likes: "999" } });
  });

  it("reads the camelCase client-store shape of the same aweme", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    vi.stubGlobal("__INITIAL_STATE__", {
      aweme: { detail: { [id]: {
        awemeId: id,
        authorInfo: { nickname: "王自如AI" },
        createTime: 1_784_505_600,
        stats: { diggCount: 12_345, commentCount: 678, shareCount: 90, collectCount: 1_234 },
      } } },
    });
    const { extractDouyinMetadataFromInitialStateInMainWorld } = await import("../src/entrypoints/background");

    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toEqual({
      author: "王自如AI",
      publishedAt: "2026-07-20T00:00:00.000Z",
      stats: { likes: "12345", comments: "678", shares: "90", collects: "1234" },
    });
  });

  const allowlistedMetadataSources: Array<[
    string,
    { globalName?: string; scriptID?: string; encoded?: boolean },
  ]> = [
    ["global __INITIAL_STATE__", { globalName: "__INITIAL_STATE__" }],
    ["global _ROUTER_DATA", { globalName: "_ROUTER_DATA" }],
    ["global _SSR_HYDRATED_DATA", { globalName: "_SSR_HYDRATED_DATA" }],
    ["raw __NEXT_DATA__ script", { scriptID: "__NEXT_DATA__" }],
    ["encoded RENDER_DATA script", { scriptID: "RENDER_DATA", encoded: true }],
    ["raw __INITIAL_STATE__ script", { scriptID: "__INITIAL_STATE__" }],
    ["raw _ROUTER_DATA script", { scriptID: "_ROUTER_DATA" }],
    ["raw _SSR_HYDRATED_DATA script", { scriptID: "_SSR_HYDRATED_DATA" }],
  ];
  it.each(allowlistedMetadataSources)("reads exact locked metadata from allowlisted %s", async (_label, source) => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    const payload = { nested: { awemeId: id, create_time: 1_784_505_600, statistics: { digg_count: 0, comment_count: 7 } } };
    const raw = JSON.stringify(payload);
    const scripts: Record<string, { textContent: string; tagName?: string }> = source.scriptID
      ? { [source.scriptID]: { textContent: source.encoded ? encodeURIComponent(raw) : raw } }
      : {};
    vi.stubGlobal("document", scriptDocument(scripts));
    if (source.globalName) vi.stubGlobal(source.globalName, payload);
    const { extractDouyinMetadataWithDiagnosticInMainWorld } = await import("../src/entrypoints/background");

    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({
      metadata: { publishedAt: "2026-07-20T00:00:00.000Z", stats: { likes: "0", comments: "7" } },
      diagnostic: { fixedRootPresent: 1, fixedRootParseable: 1, exactHit: true, rejectCode: "none" },
    });
  });

  it("skips malformed, oversized, and wrong-ID allowlisted script roots", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    const scripts: Record<string, { textContent: string; tagName?: string }> = {};
    vi.stubGlobal("document", scriptDocument(scripts));
    const { extractDouyinMetadataFromInitialStateInMainWorld } = await import("../src/entrypoints/background");

    scripts.RENDER_DATA = { textContent: "%not-json" };
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
    scripts.RENDER_DATA = { textContent: "x".repeat(2 * 1024 * 1024 + 1) };
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
    scripts.RENDER_DATA = { textContent: JSON.stringify({ aweme_id: "7123456789012345678", statistics: { digg_count: 999 } }) };
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
  });

  it("reports fixed-root parsing, exact-match, and traversal-limit diagnostics without returning page values", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    const { extractDouyinMetadataWithDiagnosticInMainWorld } = await import("../src/entrypoints/background");
    vi.stubGlobal("__INITIAL_STATE__", { nested: { aweme_id: id, statistics: { digg_count: 1 } } });
    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({
      metadata: { stats: { likes: "1" } },
      diagnostic: { fixedRootPresent: 1, fixedRootParseable: 1, exactHit: true, rejectCode: "none", limitCode: "none" },
    });
    vi.stubGlobal("__INITIAL_STATE__", { nested: { aweme_id: "7123456789012345678" } });
    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({
      metadata: null,
      diagnostic: { exactHit: false, rejectCode: "no_exact_item" },
    });
    let deep: Record<string, unknown> = { aweme_id: id, statistics: { digg_count: 1 } };
    for (let index = 0; index < 17; index += 1) deep = { nested: deep };
    vi.stubGlobal("__INITIAL_STATE__", deep);
    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({
      metadata: null,
      diagnostic: { limitCode: "depth_limit" },
    });
  });

  it("accepts exact-ID SCRIPT roots but rejects same-ID non-script elements and UTF-8 byte overflow", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    const scripts: Record<string, { textContent: string; tagName?: string }> = {
      __NEXT_DATA__: { tagName: "DIV", textContent: JSON.stringify({ aweme_id: id, statistics: { digg_count: 9 } }) },
    };
    vi.stubGlobal("document", scriptDocument(scripts));
    const { extractDouyinMetadataFromInitialStateInMainWorld } = await import("../src/entrypoints/background");

    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
    scripts.__NEXT_DATA__ = { tagName: "SCRIPT", textContent: JSON.stringify({ aweme_id: id, statistics: { digg_count: 9 } }) };
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toEqual({ stats: { likes: "9" } });
    scripts.__NEXT_DATA__ = { tagName: "SCRIPT", textContent: "中".repeat(700_000) };
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
  });

  it("requires every own aweme ID alias to be a non-empty exact locked string", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    const { extractDouyinMetadataFromInitialStateInMainWorld } = await import("../src/entrypoints/background");
    for (const candidate of [
      { aweme_id: Number(id), statistics: { digg_count: 1 } },
      { aweme_id: "", statistics: { digg_count: 2 } },
      { aweme_id: id, awemeId: "7123456789012345678", statistics: { digg_count: 3 } },
    ]) {
      vi.stubGlobal("__INITIAL_STATE__", candidate);
      expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
    }
  });

  it("shares the 20000 traversal budget across allowlisted roots", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    vi.stubGlobal("__INITIAL_STATE__", { nodes: Array.from({ length: 19_999 }, () => ({})) });
    vi.stubGlobal("_ROUTER_DATA", { nodes: [{ aweme_id: id, statistics: { digg_count: 1 } }] });
    const { extractDouyinMetadataFromInitialStateInMainWorld } = await import("../src/entrypoints/background");

    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
  });

  it("remains self-contained after MAIN-world function serialization", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    vi.stubGlobal("__INITIAL_STATE__", { awemeId: id, statistics: { digg_count: 0 } });
    const { extractDouyinMetadataWithDiagnosticInMainWorld } = await import("../src/entrypoints/background");
    const rebuilt = new Function(`return (${extractDouyinMetadataWithDiagnosticInMainWorld.toString()});`)() as typeof extractDouyinMetadataWithDiagnosticInMainWorld;

    expect(rebuilt(id)).toMatchObject({ metadata: { stats: { likes: "0" } }, diagnostic: { exactHit: true } });
  });

  it("stops as soon as one exact item supplies author, stats, and create time", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const id = "7655224917603994914";
    // The flood would reach the child budget if traversal continued after the
    // exact item, so a clean diagnostic proves the early exit is in effect.
    vi.stubGlobal("__INITIAL_STATE__", {
      aweme_id: id,
      author: { nickname: "Syc" },
      create_time: 1_784_505_600,
      statistics: { digg_count: 1 },
      flood: Array.from({ length: 20_001 }, () => 0),
    });
    const { extractDouyinMetadataWithDiagnosticInMainWorld } = await import("../src/entrypoints/background");

    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({
      metadata: { author: "Syc", publishedAt: "2026-07-20T00:00:00.000Z", stats: { likes: "1" } },
      diagnostic: { exactHit: true, limitCode: "none" },
    });
  });

  it("bounds SSR traversal and rejects unsafe numeric representations", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const {
      extractDouyinMetadataFromInitialStateInMainWorld,
      extractDouyinMetadataWithDiagnosticInMainWorld,
    } = await import("../src/entrypoints/background");
    const id = "7655224917603994914";
    vi.stubGlobal("__INITIAL_STATE__", { primitiveFlood: Array.from({ length: 20_000 }, () => 0) });
    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({ diagnostic: { limitCode: "child_limit" } });

    let deep: Record<string, unknown> = { aweme_id: id, statistics: { digg_count: 1 } };
    for (let index = 0; index < 17; index += 1) deep = { nested: deep };
    vi.stubGlobal("__INITIAL_STATE__", deep);
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();

    const nodes = Array.from({ length: 20_001 }, () => ({} as Record<string, unknown>));
    nodes[20_000] = { aweme_id: id, statistics: { digg_count: 1 } };
    vi.stubGlobal("__INITIAL_STATE__", { nodes });
    expect(extractDouyinMetadataWithDiagnosticInMainWorld(id)).toMatchObject({ diagnostic: { limitCode: "node_limit" } });

    vi.stubGlobal("__INITIAL_STATE__", {
      aweme_id: id,
      create_time: Number.MAX_SAFE_INTEGER + 1,
      statistics: { digg_count: Number.MAX_SAFE_INTEGER + 1, comment_count: "123456789012345678901" },
    });
    expect(extractDouyinMetadataFromInitialStateInMainWorld(id)).toBeNull();
  });

  it("refuses handoff when bounded containers identify only another aweme", () => {
    vi.stubGlobal("document", modalDocument([
      {
        source: "https://media.example.test/feed-b.mp4",
        paused: false,
        boundAwemeId: "7123456789012345678",
        rect: { left: 0, top: 0, right: 900, bottom: 700 },
      },
    ]));

    const media = extractDouyinSingleItemMetaInPage()?.mediaDescriptor;
    expect(media).toMatchObject({
      kind: "unsupported",
      failureReason: "multiple_candidates",
      candidateCount: 1,
      selectionReason: "ambiguous",
    });
    expect(media?.ephemeralPlaybackURL).toBeUndefined();
  });

  it("does not treat a mixed A/B identity container as a clean modal match", () => {
    const mixedIdentityContainer = {
      parentElement: null,
      getAttribute: (name: string) => name === "data-aweme-id" ? "7123456789012345678" : null,
      querySelector: (selector: string) => selector.includes("7655224917603994914")
        ? { getAttribute: () => "https://example.test/video/7655224917603994914" }
        : null,
    };
    const doc = modalDocument([
      {
        source: "https://media.example.test/mixed.mp4",
        paused: false,
        rect: { left: 0, top: 0, right: 900, bottom: 700 },
      },
    ]) as unknown as { querySelectorAll: (selector: string) => Array<{ parentElement: unknown }> };
    doc.querySelectorAll("video")[0]!.parentElement = mixedIdentityContainer;
    vi.stubGlobal("document", doc);

    expect(extractDouyinSingleItemMetaInPage()?.mediaDescriptor).toMatchObject({
      kind: "unsupported",
      failureReason: "multiple_candidates",
      selectionReason: "ambiguous",
    });
  });

  it("selects the only playing modal video before a larger paused candidate", () => {
    vi.stubGlobal("document", modalDocument([
      { source: "https://media.example.test/playing.mp4", paused: false, rect: { left: 20, top: 20, right: 220, bottom: 120 } },
      { source: "https://media.example.test/large.mp4", rect: { left: 0, top: 0, right: 900, bottom: 700 } },
    ]));

    const result = extractDouyinSingleItemMetaInPage();

    expect(result).toMatchObject({
      awemeId: "7655224917603994914",
      title: "同一快照标题",
      description: "同一快照正文",
      mediaDescriptor: {
        kind: "directFile",
        ephemeralPlaybackURL: "https://media.example.test/playing.mp4",
        candidateCount: 2,
        selectionReason: "playing",
        playbackState: "playing",
      },
    });
  });

  it("uses proven active-element interaction before area when nothing is playing", () => {
    const interactionChild = {};
    vi.stubGlobal("document", modalDocument([
      { source: "https://media.example.test/interacted.mp4", rect: { left: 20, top: 20, right: 220, bottom: 120 }, interactionChild },
      { source: "https://media.example.test/large.mp4", rect: { left: 0, top: 0, right: 900, bottom: 700 } },
    ], interactionChild));

    expect(extractDouyinSingleItemMetaInPage()?.mediaDescriptor).toMatchObject({
      ephemeralPlaybackURL: "https://media.example.test/interacted.mp4",
      selectionReason: "recentInteraction",
    });
  });

  it("selects the largest visible modal video when none is playing or interacted", () => {
    vi.stubGlobal("document", modalDocument([
      { source: "https://media.example.test/small.mp4", rect: { left: 20, top: 20, right: 220, bottom: 120 } },
      { source: "https://media.example.test/large.mp4", rect: { left: 100, top: 100, right: 800, bottom: 650 } },
    ]));

    expect(extractDouyinSingleItemMetaInPage()?.mediaDescriptor).toMatchObject({
      kind: "directFile",
      ephemeralPlaybackURL: "https://media.example.test/large.mp4",
      selectionReason: "largestVisibleArea",
      playbackState: "paused",
    });
  });

  it("uses viewport-center distance when visible areas tie", () => {
    vi.stubGlobal("document", modalDocument([
      { source: "https://media.example.test/edge.mp4", rect: { left: 0, top: 0, right: 200, bottom: 100 } },
      { source: "https://media.example.test/center.mp4", rect: { left: 400, top: 350, right: 600, bottom: 450 } },
    ]));

    expect(extractDouyinSingleItemMetaInPage()?.mediaDescriptor).toMatchObject({
      ephemeralPlaybackURL: "https://media.example.test/center.mp4",
      selectionReason: "nearestViewportCenter",
    });
  });

  it("reports ambiguity only when all deterministic modal-video signals tie", () => {
    const rect = { left: 100, top: 100, right: 500, bottom: 400 };
    vi.stubGlobal("document", modalDocument([
      { source: "https://media.example.test/a.mp4", rect },
      { source: "https://media.example.test/b.mp4", rect },
    ]));

    expect(extractDouyinSingleItemMetaInPage()?.mediaDescriptor).toMatchObject({
      kind: "unsupported",
      failureReason: "multiple_candidates",
      candidateCount: 2,
      selectionReason: "ambiguous",
      playbackState: "unknown",
    });
  });

  it("rejects an adversarially large candidate set without exposing its count", () => {
    const fixtures = Array.from({ length: 1001 }, (_, index) => ({
      source: `https://media.example.test/${index}.mp4`,
      rect: { left: 0, top: 0, right: 10, bottom: 10 },
    }));
    vi.stubGlobal("document", modalDocument(fixtures));

    const media = extractDouyinSingleItemMetaInPage()?.mediaDescriptor;
    expect(media).toMatchObject({
      kind: "unsupported",
      failureReason: "multiple_candidates",
      selectionReason: "ambiguous",
    });
    expect(media?.candidateCount).toBeUndefined();
  });

  it("keeps pure text on V1 and uses V2 only for a classified target video", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureEnvelopeForPage } = await import("../src/entrypoints/background");
    const page = {
      title: "Article",
      url: "https://example.test/article",
      text: "article body",
      characterCount: 12,
      method: "rendered_dom" as const,
    };
    expect(captureEnvelopeForPage(page, page.url, page.title, "2026-07-20T00:00:00Z", "v1").version).toBe(1);
    expect(captureEnvelopeForPage({
      ...page,
      mediaDescriptor: {
        kind: "browserSessionOnly" as const,
        pageURL: page.url,
        canonicalURL: page.url,
        platform: "generic" as const,
        transcriptionCapability: "unavailable" as const,
        failureReason: "blob_or_mse" as const,
      },
    }, page.url, page.title, "2026-07-20T00:00:00Z", "v2").version).toBe(2);
  });

  it("builds an allowlisted popup preview without body or media URLs", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { safePreviewForCapture } = await import("../src/entrypoints/background");
    const preview = safePreviewForCapture({
      version: 2,
      requestId: "preview",
      createdAt: "2026-07-20T00:00:00Z",
      source: { kind: "browser_capture", url: "https://example.test/video", title: "Preview title", platform: "generic" },
      capture: { method: "rendered_dom", text: "private body sentinel", characterCount: 21, completeness: "full_article", capturedAt: "2026-07-20T00:00:00Z" },
      evidence: { sourceLabel: "Current page DOM", usedCookie: false },
      media: {
        kind: "directFile",
        pageURL: "https://example.test/video",
        canonicalURL: "https://example.test/video",
        platform: "generic",
        ephemeralPlaybackURL: "https://media.example.test/signed.mp4?secret=sentinel",
        posterURL: "https://media.example.test/private-poster.jpg",
        transcriptionCapability: "supported",
        candidateCount: 2,
        selectionReason: "playing",
        playbackState: "playing",
      },
    }, { code: "no_allowed_host", blockedHost: "blocked.example" });

    expect(preview).toEqual({
      title: "Preview title",
      characterCount: 21,
      version: 2,
      platform: "generic",
      completeness: "full_article",
      media: { kind: "directFile", candidateCount: 2, selectionReason: "playing", playbackState: "playing" },
      mediaDiagnostic: { code: "no_allowed_host", blockedHost: "blocked.example" },
    });
    expect(JSON.stringify(preview)).not.toContain("sentinel");
    expect(JSON.stringify(preview)).not.toContain("poster");
    expect(JSON.stringify(preview)).not.toContain("private body");
  });

  it("sanitizes untrusted MAIN-world diagnostics before popup use", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { safeDouyinSessionDiagnostic } = await import("../src/entrypoints/background");

    expect(safeDouyinSessionDiagnostic({
      ok: false,
      code: "no_allowed_host",
      blockedHost: "blocked.example",
      rawURL: "https://blocked.example/private?token=sentinel",
      body: "sentinel body",
    })).toEqual({ code: "no_allowed_host", blockedHost: "blocked.example" });
    expect(safeDouyinSessionDiagnostic({
      ok: false,
      code: "http_403",
      blockedHost: "must-not-survive.example",
    })).toEqual({ code: "http_403" });
    expect(safeDouyinSessionDiagnostic({
      ok: false,
      code: "no_allowed_host",
      blockedHost: "User@Blocked.Example/path?token=sentinel",
    })).toEqual({ code: "no_allowed_host" });
    expect(safeDouyinSessionDiagnostic({ ok: false, code: "raw-private-error" })).toBeUndefined();
  });

  it("rebuilds preview diagnostics from an allowlist instead of copying extra fields", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { safePreviewForCapture } = await import("../src/entrypoints/background");
    const envelope = {
      version: 1 as const,
      requestId: "safe-diagnostic-preview",
      createdAt: "2026-07-20T00:00:00Z",
      source: { kind: "browser_capture" as const, url: "https://example.test", title: "Preview", platform: "generic" as const },
      capture: { method: "rendered_dom" as const, text: "body", characterCount: 4, completeness: "full_article" as const, capturedAt: "2026-07-20T00:00:00Z" },
      evidence: { sourceLabel: "Current page DOM", usedCookie: false as const },
    };
    const preview = safePreviewForCapture(envelope, {
      code: "no_allowed_host",
      blockedHost: "blocked.example",
      rawBody: "sentinel-private-body",
      rawURL: "https://blocked.example/private?token=sentinel",
    } as never);

    expect(preview.mediaDiagnostic).toEqual({ code: "no_allowed_host", blockedHost: "blocked.example" });
    expect(JSON.stringify(preview)).not.toContain("sentinel");
    expect(JSON.stringify(preview)).not.toContain("rawBody");
    expect(JSON.stringify(preview)).not.toContain("rawURL");
  });

  it("contains the detail endpoint only in the bounded MAIN module and never reads browser secrets", () => {
    const background = readFileSync(new URL("../src/entrypoints/background.ts", import.meta.url), "utf8");
    const extraction = readFileSync(new URL("../src/content/extract.ts", import.meta.url), "utf8");
    const sessionDetail = readFileSync(new URL("../src/content/douyin-session-detail.ts", import.meta.url), "utf8");
    for (const source of [background, extraction]) {
      expect(source).not.toContain("/aweme/v1/web/aweme/detail/");
    }
    expect(sessionDetail.match(/\/aweme\/v1\/web\/aweme\/detail\//gu)).toHaveLength(1);
    expect(sessionDetail).toMatch(/credentials\s*:\s*["']same-origin["']/u);
    for (const source of [background, extraction, sessionDetail]) {
      expect(source).not.toMatch(/credentials\s*:\s*["']include["']/u);
      expect(source).not.toMatch(/document\.cookie|chrome\.cookies|browser\.cookies|localStorage|sessionStorage|performance\.getEntries/gu);
    }
    const config = readFileSync(new URL("../wxt.config.ts", import.meta.url), "utf8");
    expect(config).not.toMatch(/host_permissions|cookies|webRequest|declarativeNetRequest/u);
  });

  it("runs MAIN fallback only for the locked blob/MSE descriptor and double-validates its URL", async () => {
    const id = "7655224917603994914";
    const blob = {
      kind: "browserSessionOnly" as const,
      platform: "douyin" as const,
      pageURL: `https://www.douyin.com/video/${id}`,
      canonicalURL: `https://www.douyin.com/video/${id}`,
      transcriptionCapability: "unavailable" as const,
      failureReason: "blob_or_mse" as const,
    };
    // Call sequence: 1) meta extraction, 2) __INITIAL_STATE__ (fails), 3) session detail API (succeeds)
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
        awemeId: id, title: "Blob video", author: "作者", description: "正文", mediaDescriptor: blob,
      } }])
      .mockResolvedValueOnce([{ result: { ok: false } }])
      .mockResolvedValueOnce([{ result: {
        ok: true,
        playbackURL: "https://v3.douyinvod.com/video.mp4?token=temporary",
        candidateCount: 2,
      } }]);
    vi.stubGlobal("browser", { scripting: { executeScript } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureDouyinSingleItem } = await import("../src/entrypoints/background");

    const page = await captureDouyinSingleItem(1, `https://www.douyin.com/video/${id}`);

    expect(executeScript).toHaveBeenCalledTimes(4);
    expect(executeScript.mock.calls[2]?.[0]).toMatchObject({
      target: { tabId: 1, frameIds: [0] },
      world: "MAIN",
      args: [id],
    });
    expect(page.mediaDescriptor).toMatchObject({
      kind: "directFile",
      ephemeralPlaybackURL: "https://v3.douyinvod.com/video.mp4?token=temporary",
      transcriptionCapability: "supported",
      candidateCount: 2,
    });
    expect(page.mediaDescriptor?.failureReason).toBeUndefined();
    expect(page.usedCookie).toBe(true);
  });

  it("keeps the locked blob descriptor and text when MAIN fallback fails or returns an evil host", async () => {
    const id = "7655224917603994914";
    const meta = {
      awemeId: id,
      title: "Blob video",
      author: "作者",
      description: "正文仍发送",
      mediaDescriptor: {
        kind: "browserSessionOnly" as const,
        platform: "douyin" as const,
        pageURL: `https://www.douyin.com/video/${id}`,
        canonicalURL: `https://www.douyin.com/video/${id}`,
        transcriptionCapability: "unavailable" as const,
        failureReason: "blob_or_mse" as const,
      },
    };
    // Call sequence: 1) meta extraction, 2) __INITIAL_STATE__ (fails), 3) session detail API (evil host)
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: meta }])
      .mockResolvedValueOnce([{ result: { ok: false } }])
      .mockResolvedValueOnce([{ result: { ok: true, playbackURL: "https://douyinvod.com.evil.test/video.mp4", candidateCount: 1 } }]);
    vi.stubGlobal("browser", { scripting: { executeScript } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureDouyinSingleItem, captureEnvelopeForPage } = await import("../src/entrypoints/background");

    const page = await captureDouyinSingleItem(1, `https://www.douyin.com/video/${id}`);
    const envelope = captureEnvelopeForPage(page, page.url, page.title, "2026-07-20T00:00:00Z", "failed-fallback");

    expect(page.text).toContain("正文仍发送");
    expect(page.mediaDescriptor).toMatchObject({ kind: "browserSessionOnly", failureReason: "blob_or_mse" });
    expect(page.usedCookie).toBeUndefined();
    expect(page.mediaDiagnostic).toEqual({
      code: "no_allowed_host",
      blockedHost: "douyinvod.com.evil.test",
    });
    expect(envelope.evidence).toEqual({ sourceLabel: "Current page DOM", usedCookie: false });
    expect(JSON.stringify(envelope)).not.toContain("evil.test");
    expect(JSON.stringify(envelope)).not.toContain("mediaDiagnostic");
  });

  it("maps executeScript rejection to main_injection_failed without raw exception text", async () => {
    const id = "7655224917603994914";
    // Call sequence: 1) meta, 2) __INITIAL_STATE__ (rejected, silently caught), 3) session API (rejected)
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
        awemeId: id,
        title: "Blob video",
        description: "正文仍发送",
        mediaDescriptor: {
          kind: "browserSessionOnly",
          platform: "douyin",
          pageURL: `https://www.douyin.com/video/${id}`,
          canonicalURL: `https://www.douyin.com/video/${id}`,
          transcriptionCapability: "unavailable",
          failureReason: "blob_or_mse",
        },
      } }])
      .mockRejectedValueOnce(new Error("sentinel-private-state-error"))
      .mockRejectedValueOnce(new Error("sentinel-private-injection-error"));
    vi.stubGlobal("browser", { scripting: { executeScript } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureDouyinSingleItem, captureEnvelopeForPage } = await import("../src/entrypoints/background");

    const page = await captureDouyinSingleItem(1, `https://www.douyin.com/video/${id}`);
    const envelope = captureEnvelopeForPage(page, page.url, page.title, "2026-07-20T00:00:00Z", "inject-failed");

    expect(page.mediaDiagnostic).toEqual({ code: "main_injection_failed" });
    expect(JSON.stringify(page)).not.toContain("sentinel-private-injection-error");
    expect(JSON.stringify(envelope)).not.toContain("main_injection_failed");
    expect(JSON.stringify(envelope)).not.toContain("mediaDiagnostic");
  });

  it("keeps directFile on DOM playback while merging MAIN metadata without session detail or cookie use", async () => {
    const id = "7655224917603994914";
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
      awemeId: id,
      title: "Direct",
      description: "正文",
      mediaDescriptor: {
        kind: "directFile",
        platform: "douyin",
        pageURL: `https://www.douyin.com/video/${id}`,
        canonicalURL: `https://www.douyin.com/video/${id}`,
        ephemeralPlaybackURL: "https://v3.douyinvod.com/direct.mp4",
        transcriptionCapability: "supported",
      },
      } }])
      .mockResolvedValueOnce([{ result: {
        metadata: { publishedAt: "2026-07-20T00:00:00.000Z", stats: { likes: "0", comments: "7" } },
        diagnostic: {
          fixedRootPresent: 1, fixedRootParseable: 1, exactHit: true,
          rejectCode: "none", limitCode: "none",
        },
      } }]);
    vi.stubGlobal("browser", { scripting: { executeScript } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureDouyinSingleItem, extractDouyinMetadataWithDiagnosticInMainWorld } = await import("../src/entrypoints/background");

    const page = await captureDouyinSingleItem(1, `https://www.douyin.com/video/${id}`);
    expect(executeScript).toHaveBeenCalledTimes(2);
    expect(executeScript.mock.calls[1]?.[0]).toMatchObject({ world: "MAIN", args: [id] });
    expect(executeScript.mock.calls[1]?.[0].func).toBe(extractDouyinMetadataWithDiagnosticInMainWorld);
    expect(page.text).toContain('published: "2026-07-20T00:00:00.000Z"');
    expect(page.text).toContain('likes: "0"');
    expect(page.text).toContain('comments: "7"');
    expect(page.usedCookie).toBeUndefined();
  });

  it("keeps missing-metadata diagnostics popup-only and recursively absent from the native wire envelope", async () => {
    const id = "7655224917603994914";
    const domDiagnostic = {
      route: { eligible: true, rejectCode: "none" as const },
      video: { positiveVisibleCount: 1, dominantVideoCount: 1, rejectCode: "none" as const },
      scopes: { safeCount: 1, dedicatedCount: 0, rejectCode: "none" as const },
      dom: { publishedSelectorHit: false, statSelectorHitMask: 1, statAcceptedCount: 1 },
    };
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
        awemeId: id, title: "页面标题", author: null, description: "正文", pageURL: `https://www.douyin.com/video/${id}`,
        stats: { likes: "1" }, metadataDiagnostic: domDiagnostic,
      } }])
      .mockResolvedValueOnce([{ result: {
        metadata: null,
        diagnostic: { fixedRootPresent: 1, fixedRootParseable: 1, exactHit: false, rejectCode: "no_exact_item", limitCode: "none" },
      } }]);
    let wire: unknown;
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({ url: `https://www.douyin.com/video/${id}`, title: "页面标题" }) },
      scripting: { executeScript },
      runtime: { sendNativeMessage: vi.fn(async (_host: string, envelope: unknown) => {
        wire = envelope;
        return { kind: "taskAccepted", version: 1, requestId: (envelope as { requestId: string }).requestId, characterCount: 2 };
      }) },
    });
    vi.stubGlobal("crypto", { randomUUID: vi.fn(() => "metadata-wire") });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { sendCapture } = await import("../src/entrypoints/background");
    const result = await sendCapture(1);
    const containsDiagnosticKey = (value: unknown): boolean => {
      if (!value || typeof value !== "object") return false;
      if (Array.isArray(value)) return value.some(containsDiagnosticKey);
      return Object.entries(value as Record<string, unknown>).some(([key, child]) =>
        key === "metadataDiagnostic" || key === "mediaDiagnostic" || containsDiagnosticKey(child));
    };

    expect(result.metadataDiagnostic).toMatchObject({ missingPublished: true, missingStatsMask: 14 });
    expect(JSON.stringify(result.metadataDiagnostic)).not.toContain("页面标题");
    expect(containsDiagnosticKey(wire)).toBe(false);
    expect(JSON.stringify(wire)).not.toContain("no_exact_item");
  });

  it("marks successful V2 evidence true while V1 remains false and preview hides the fresh URL", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureEnvelopeForPage, safePreviewForCapture } = await import("../src/entrypoints/background");
    const base = {
      title: "Video",
      url: "https://www.douyin.com/video/7655224917603994914",
      text: "正文",
      characterCount: 2,
      method: "rendered_dom" as const,
      usedCookie: true,
    };
    const v1 = captureEnvelopeForPage(base, base.url, base.title, "2026-07-20T00:00:00Z", "v1-cookie-guard");
    const v2 = captureEnvelopeForPage({
      ...base,
      mediaDescriptor: {
        kind: "directFile" as const,
        pageURL: base.url,
        canonicalURL: base.url,
        platform: "douyin" as const,
        ephemeralPlaybackURL: "https://v3.douyinvod.com/private.mp4?token=sentinel",
        transcriptionCapability: "supported" as const,
      },
    }, base.url, base.title, "2026-07-20T00:00:00Z", "v2-cookie-true");

    expect(v1).toMatchObject({ version: 1, evidence: { sourceLabel: "Current page DOM", usedCookie: false } });
    expect(v2).toMatchObject({
      version: 2,
      evidence: { sourceLabel: "Current page DOM + same-origin session detail", usedCookie: true },
    });
    expect(JSON.stringify(safePreviewForCapture(v2))).not.toContain("sentinel");
    expect(JSON.stringify(safePreviewForCapture(v2))).not.toContain("douyinvod");
  });

  it("runs preview and send as separate fresh captures without reusing the preview URL", async () => {
    const id = "7655224917603994914";
    const previewURL = "https://v3.douyinvod.com/preview.mp4?token=preview-only";
    const sendURL = "https://v3.douyinvod.com/send.mp4?token=send-only";
    const sessionURLs = [previewURL, sendURL];
    const meta = {
      awemeId: id,
      title: "Fresh video",
      description: "fresh body",
      mediaDescriptor: {
        kind: "browserSessionOnly",
        platform: "douyin",
        pageURL: `https://www.douyin.com/video/${id}`,
        canonicalURL: `https://www.douyin.com/video/${id}`,
        transcriptionCapability: "unavailable",
        failureReason: "blob_or_mse",
      },
    };
    // Call sequence per capture: 1) meta (isolated), 2) __INITIAL_STATE__ (MAIN, fails), 3) session API (MAIN, succeeds)
    // Two captures (preview + send) = 6 total calls, 4 MAIN world.
    const executeScript = vi.fn(async (injection: { world?: string; func?: unknown }) => {
      // __INITIAL_STATE__ extraction always fails — fall through to session API
      if (injection.world === "MAIN" && injection.func?.toString().includes("__INITIAL_STATE__")) {
        return [{ result: { ok: false } }];
      }
      if (injection.world === "MAIN") {
        return [{ result: { ok: true, playbackURL: sessionURLs.shift(), candidateCount: 1 } }];
      }
      return [{ result: meta }];
    });
    let sentEnvelope: Record<string, unknown> | undefined;
    vi.stubGlobal("browser", {
      tabs: { get: vi.fn().mockResolvedValue({ url: `https://www.douyin.com/video/${id}`, title: "Fresh video" }) },
      scripting: { executeScript },
      runtime: {
        sendNativeMessage: vi.fn(async (_host: string, envelope: Record<string, unknown>) => {
          sentEnvelope = envelope;
          return {
            kind: "taskAccepted", version: 1, requestId: envelope.requestId, characterCount: 72,
          };
        }),
      },
    });
    vi.stubGlobal("crypto", {
      randomUUID: vi.fn().mockReturnValueOnce("preview-request").mockReturnValueOnce("send-request"),
    });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { previewCurrentPage, sendCapture } = await import("../src/entrypoints/background");

    const preview = await previewCurrentPage(1);
    const response = await sendCapture(1);

    expect(JSON.stringify(preview)).not.toContain("preview-only");
    expect(response).toMatchObject({ response: { kind: "taskAccepted", requestId: "send-request" } });
    expect(sentEnvelope).toMatchObject({
      requestId: "send-request",
      evidence: { sourceLabel: "Current page DOM + same-origin session detail", usedCookie: true },
      media: { kind: "directFile", ephemeralPlaybackURL: sendURL },
    });
    expect(JSON.stringify(sentEnvelope)).not.toContain("preview-only");
    expect(executeScript).toHaveBeenCalledTimes(8);
    expect(executeScript.mock.calls.filter(([injection]) => injection.world === "MAIN")).toHaveLength(6);
  });

  it("returns only safe extension_validation, native_response, and native_transport stages", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    vi.stubGlobal("crypto", { randomUUID: vi.fn(() => "safe-stage-request") });
    const { sendCapture } = await import("../src/entrypoints/background");
    const page = {
      title: "Safe stage",
      url: "https://example.test/article",
      text: "body",
      characterCount: 4,
      method: "rendered_dom",
    };
    const browserFor = (capturedPage: typeof page, nativeResult: () => unknown) => {
      const sendNativeMessage = vi.fn(async () => nativeResult());
      vi.stubGlobal("browser", {
        tabs: { get: vi.fn().mockResolvedValue({ url: capturedPage.url, title: capturedPage.title }) },
        scripting: { executeScript: vi.fn()
          .mockResolvedValueOnce([{ result: capturedPage }])
          .mockResolvedValueOnce([{ result: undefined }]) },
        runtime: { sendNativeMessage },
      });
      return sendNativeMessage;
    };

    const validationNative = browserFor({ ...page, characterCount: 99 }, () => ({ kind: "taskAccepted" }));
    const validation = await sendCapture(1);
    expect(validation).toMatchObject({
      errorStage: "extension_validation",
      response: { kind: "error", error: { code: "CAPTURE_COUNT_MISMATCH" } },
    });
    expect(validationNative).not.toHaveBeenCalled();

    browserFor(page, () => ({ kind: "unknown", safeDetail: "sentinel-private-native-body" }));
    const nativeResponse = await sendCapture(1);
    expect(nativeResponse).toMatchObject({
      errorStage: "native_response",
      response: { kind: "error", error: { code: "NATIVE_RESPONSE_INVALID" } },
    });
    expect(JSON.stringify(nativeResponse)).not.toContain("sentinel-private-native-body");

    browserFor(page, () => Promise.reject(new Error("sentinel-private-transport-error")));
    const transport = await sendCapture(1);
    expect(transport).toMatchObject({
      errorStage: "native_transport",
      response: { kind: "error", error: { code: "NATIVE_MESSAGE_FAILED" } },
    });
    expect(JSON.stringify(transport)).not.toContain("sentinel-private-transport-error");
  });

  it("does not pass video B media to the text and canonical URL locked for video A", async () => {
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { mediaHitForLockedDouyinItem } = await import(
      "../src/entrypoints/background"
    );
    const lockedAwemeId = "7635842095491632418";
    const videoBURL = "https://cdn.example.test/video-b.mp4";

    const mismatched = mediaHitForLockedDouyinItem(lockedAwemeId, {
      kind: "directFile",
      platform: "douyin",
      pageURL: "https://www.douyin.com/video/7123456789012345678",
      canonicalURL: "https://www.douyin.com/video/7123456789012345678",
      ephemeralPlaybackURL: videoBURL,
      transcriptionCapability: "supported",
      author: "作者 B",
    });

    expect(mismatched).toBeUndefined();
    expect(mismatched?.ephemeralPlaybackURL).not.toBe(videoBURL);

    const matched = mediaHitForLockedDouyinItem(lockedAwemeId, {
      kind: "directFile",
      platform: "douyin",
      pageURL: `https://www.douyin.com/video/${lockedAwemeId}`,
      canonicalURL: `https://www.douyin.com/video/${lockedAwemeId}`,
      ephemeralPlaybackURL: "https://cdn.example.test/video-a.mp4",
      transcriptionCapability: "supported",
    });
    expect(matched?.ephemeralPlaybackURL).toContain("video-a.mp4");
  });

  it("captures Douyin text and media from one atomic injection even if a second result would be video B", async () => {
    const videoA = "7635842095491632418";
    const videoB = "7123456789012345678";
    const executeScript = vi.fn()
      .mockResolvedValueOnce([{ result: {
        awemeId: videoB,
        canonicalURL: `https://www.douyin.com/video/${videoB}`,
        pageURL: `https://www.douyin.com/video/${videoB}?snapshot=B`,
        title: "视频 B",
        author: "作者 B",
        description: "正文 B",
        mediaDescriptor: {
          kind: "directFile",
          platform: "douyin",
          pageURL: `https://www.douyin.com/video/${videoB}?snapshot=B`,
          canonicalURL: `https://www.douyin.com/video/${videoB}`,
          ephemeralPlaybackURL: "https://cdn.example.test/video-b.mp4",
          transcriptionCapability: "supported",
        },
      } }])
      .mockResolvedValueOnce([{ result: {
        ephemeralPlaybackURL: "https://cdn.example.test/impossible-second-result.mp4",
      } }]);
    vi.stubGlobal("browser", { scripting: { executeScript } });
    vi.stubGlobal("defineBackground", (factory: unknown) => factory);
    const { captureDouyinSingleItem } = await import("../src/entrypoints/background");

    const page = await captureDouyinSingleItem(1, `https://www.douyin.com/video/${videoA}`);

    expect(executeScript).toHaveBeenCalledTimes(2);
    expect(page.text).toContain("正文 B");
    expect(page.url).toBe(`https://www.douyin.com/video/${videoB}`);
    expect(page.mediaDescriptor?.pageURL).toBe(`https://www.douyin.com/video/${videoB}?snapshot=B`);
    expect(page.mediaDescriptor?.canonicalURL).toBe(`https://www.douyin.com/video/${videoB}`);
    expect(JSON.stringify(page)).not.toContain(videoA);
  });
});
