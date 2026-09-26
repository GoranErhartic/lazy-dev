import { Cursor } from "@cursor/sdk";
import type { ModelConfig } from "./global.js";

export interface ModelChoice {
  id: string;
  label: string;
}

export async function fetchModels(apiKey: string): Promise<ModelChoice[]> {
  const models = await Cursor.models.list({ apiKey });
  return models.map((model) => ({
    id: model.id,
    label: model.displayName && model.displayName !== model.id ? `${model.id}  ${model.displayName}` : model.id,
  }));
}

export function defaultModel(models: ModelChoice[], preferred?: string): string | undefined {
  if (preferred && models.some((model) => model.id === preferred)) return preferred;
  return models.find((model) => model.id.startsWith("composer-2"))?.id ?? models[0]?.id;
}

export function defaultModels(models: ModelChoice[], current?: Partial<ModelConfig>): Partial<ModelConfig> {
  return {
    impl: defaultModel(models, current?.impl),
    review: defaultModel(models, current?.review),
    review2: defaultModel(models, current?.review2),
  };
}

/** Subsequence match, ranked by contiguous hits and earliness. */
export function fuzzyFilter<T extends ModelChoice>(items: T[], query: string): T[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return items;
  const scored: Array<{ item: T; score: number }> = [];
  for (const item of items) {
    const haystack = item.label.toLowerCase();
    let position = -1;
    let score = 0;
    let previous = -2;
    let matched = true;
    for (const char of needle) {
      position = haystack.indexOf(char, position + 1);
      if (position === -1) {
        matched = false;
        break;
      }
      score += position === previous + 1 ? 3 : 1;
      previous = position;
    }
    if (!matched) continue;
    if (haystack.includes(needle)) score += 10;
    scored.push({ item, score: score - haystack.indexOf(needle[0]) * 0.01 });
  }
  return scored.sort((left, right) => right.score - left.score).map((entry) => entry.item);
}
