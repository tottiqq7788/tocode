import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { SessionManager } from "../../src/core/session-manager.ts";

const REDACTION_ENV = "TOGENT_REDACT_PERSISTED_IMAGES";
const IMAGE_PLACEHOLDER = "[已从持久会话移除归档图片正文；如仍需识图，请重新读取原工作区相对路径。]";

function imageMessage(data: string, timestamp: number) {
	return {
		role: "user" as const,
		content: [
			{ type: "image" as const, data, mimeType: "image/png" },
			{ type: "text" as const, text: "请描述图片" },
		],
		timestamp,
	};
}

describe("Togent persisted image redaction", () => {
	let tempDir: string;
	let previousSetting: string | undefined;

	beforeEach(() => {
		tempDir = join(tmpdir(), `togent-session-redact-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		mkdirSync(tempDir, { recursive: true });
		previousSetting = process.env[REDACTION_ENV];
		process.env[REDACTION_ENV] = "1";
	});

	afterEach(() => {
		if (previousSetting === undefined) {
			delete process.env[REDACTION_ENV];
		} else {
			process.env[REDACTION_ENV] = previousSetting;
		}
		if (existsSync(tempDir)) {
			rmSync(tempDir, { recursive: true, force: true });
		}
	});

	it("redacts initial, appended, and rewritten JSONL without mutating live entries", () => {
		const firstImage = "TOGENT_FIRST_IMAGE_BASE64";
		const secondImage = "TOGENT_SECOND_IMAGE_BASE64";
		const manager = SessionManager.create(tempDir, tempDir);
		const firstId = manager.appendMessage(imageMessage(firstImage, 1));

		const originalFile = manager.getSessionFile();
		expect(originalFile).toBeTruthy();
		expect(readFileSync(originalFile!, "utf8")).not.toContain(firstImage);
		expect(readFileSync(originalFile!, "utf8")).toContain(IMAGE_PLACEHOLDER);
		expect(JSON.stringify(manager.getEntries())).toContain(firstImage);

		const secondId = manager.appendMessage(imageMessage(secondImage, 2));
		const appended = readFileSync(originalFile!, "utf8");
		expect(appended).not.toContain(firstImage);
		expect(appended).not.toContain(secondImage);
		expect(JSON.stringify(manager.getEntries())).toContain(secondImage);

		const branchedFile = manager.createBranchedSession(secondId);
		expect(branchedFile).toBeTruthy();
		const rewritten = readFileSync(branchedFile!, "utf8");
		expect(rewritten).not.toContain(firstImage);
		expect(rewritten).not.toContain(secondImage);
		expect(rewritten.split(IMAGE_PLACEHOLDER).length - 1).toBe(2);
		expect(JSON.stringify(manager.getEntries())).toContain(firstImage);
		expect(JSON.stringify(manager.getEntries())).toContain(secondImage);
		expect(manager.getEntries().some((entry) => entry.id === firstId)).toBe(true);
	});

	it("redacts legacy image bodies while copying a session into another project", () => {
		const legacyImage = "TOGENT_LEGACY_IMAGE_BASE64";
		delete process.env[REDACTION_ENV];
		const source = SessionManager.create(tempDir, join(tempDir, "source"));
		source.appendMessage(imageMessage(legacyImage, 1));
		const sourceFile = source.getSessionFile();
		expect(sourceFile).toBeTruthy();
		expect(readFileSync(sourceFile!, "utf8")).toContain(legacyImage);

		process.env[REDACTION_ENV] = "1";
		const forked = SessionManager.forkFrom(
			sourceFile!,
			join(tempDir, "target-project"),
			join(tempDir, "target-sessions"),
		);
		const forkedFile = forked.getSessionFile();
		expect(forkedFile).toBeTruthy();
		expect(readFileSync(forkedFile!, "utf8")).not.toContain(legacyImage);
		expect(readFileSync(forkedFile!, "utf8")).toContain(IMAGE_PLACEHOLDER);
	});
});
