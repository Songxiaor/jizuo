import { makeAppError, type AppError } from "./contract";

export function withTimeout<T>(promise: Promise<T>, milliseconds: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("NATIVE_MESSAGE_TIMEOUT")), milliseconds);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error: unknown) => { clearTimeout(timer); reject(error); },
    );
  });
}

export function mapNativeFailure(error: unknown, requestId: string): AppError {
  const message = error instanceof Error ? error.message.toLowerCase() : "";
  if (message.includes("native_message_timeout")) return makeAppError(requestId, "network", "NATIVE_MESSAGE_TIMEOUT", true, "retry");
  if (message.includes("specified native messaging host not found")) return makeAppError(requestId, "network", "NATIVE_HOST_NOT_FOUND", false, "open_install_guide");
  if (message.includes("native host has exited") || message.includes("failed to start native messaging host")) {
    return makeAppError(requestId, "network", "NATIVE_HOST_START_FAILED", false, "open_install_guide");
  }
  return makeAppError(requestId, "network", "NATIVE_MESSAGE_FAILED", true, "retry");
}
