import type { CaptureQualityIssueCode, ExtractedPage } from "./extract";

/**
 * Soft-gate capture quality issues before Native Messaging.
 *
 * Hard failures (security challenge / empty / load failed) still block.
 * Soft failures (login wall / app shell / navigation-only) are allowed when the
 * user already selected text, or the rendered body is clearly useful — that is
 * the desktop “logged-in current page” path for SPA / paywall-adjacent pages.
 */
export function captureSendBlockReason(page: {
  captureIssue?: CaptureQualityIssueCode;
  completeness?: ExtractedPage["completeness"];
  characterCount: number;
}): CaptureQualityIssueCode | undefined {
  const issue = page.captureIssue;
  if (!issue) return undefined;

  if (page.completeness === "selection_only" && page.characterCount >= 20) {
    return undefined;
  }

  const softAllow: ReadonlySet<CaptureQualityIssueCode> = new Set([
    "CAPTURE_LOGIN_WALL",
    "CAPTURE_APP_SHELL",
    "CAPTURE_NAVIGATION_ONLY",
  ]);
  if (softAllow.has(issue) && page.characterCount >= 200) {
    return undefined;
  }

  return issue;
}
