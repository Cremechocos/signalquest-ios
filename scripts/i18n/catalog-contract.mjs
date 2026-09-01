export const CATALOG_PATHS = [
  'SignalQuestApp/Resources/Localizable.xcstrings',
  'SignalQuestApp/Resources/InfoPlist.xcstrings',
  'SignalQuestWidget/Localizable.xcstrings',
  'SignalQuestNotificationService/Localizable.xcstrings',
];
export const BUNDLE_PLISTS = [
  'SignalQuestApp/Info.plist',
  'SignalQuestWidget/Info.plist',
  'SignalQuestNotificationService/Info.plist',
];

export function stringUnits(localization, prefix = '') {
  if (!localization || typeof localization !== 'object') return new Map();
  if (localization.stringUnit) return new Map([[prefix, localization.stringUnit]]);
  return new Map(Object.entries(localization).flatMap(([key, value]) =>
    [...stringUnits(value, prefix ? `${prefix}.${key}` : key)]));
}

export function materializedFrench(entry, key) {
  const french = structuredClone(entry.localizations?.fr ?? {stringUnit:{state:'translated',value:key}});
  // Xcode does not emit `new` units, even in the source localization. These
  // already-authored French values need the translated state to be compiled.
  for (const value of stringUnits(french).values()) {
    if (value.state === 'new') value.state = 'translated';
  }
  return french;
}

export function formatSignature(value) {
  const args = new Map();
  let next = 0;
  const pattern = /%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|L|z|t|j)?([@a-zA-Z%])/g;
  for (const match of value.matchAll(pattern)) {
    if (match[3] === '%') continue;
    const index = match[1] ? Number(match[1]) : ++next;
    if (index < 1) throw new Error('Invalid format argument index');
    const types = args.get(index) ?? new Set();
    types.add(`${match[2] ?? ''}${match[3]}`);
    args.set(index, types);
  }
  return JSON.stringify([...args].sort(([left], [right]) => left - right)
    .map(([index, types]) => [index, [...types].sort()]));
}

export function markupSignature(value) {
  const tags = [...value.matchAll(/<\/?([A-Za-z][\w:.-]*)\b[^>]*>/g)].map((match) => match[0]).sort();
  const links = [...value.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)].map((match) => match[1]).sort();
  return JSON.stringify({
    tags, links,
    bold: (value.match(/\*\*/g) ?? []).length,
    code: (value.match(/`/g) ?? []).length,
    lineBreaks: (value.match(/\n/g) ?? []).length,
  });
}

export function auditCatalog(catalog) {
  const failures = [];
  if (catalog.sourceLanguage !== 'fr') failures.push('French editorial source must remain fr');
  const strings = catalog.strings;
  if (!strings || typeof strings !== 'object') return { failures: ['Missing strings'], keys: 0 };
  let stale = 0;
  let variants = 0;
  for (const [key, entry] of Object.entries(strings)) {
    if (entry.extractionState === 'stale') stale++;
    const fr = stringUnits(entry.localizations?.fr);
    const en = stringUnits(entry.localizations?.en);
    if (!fr.size) failures.push(`${key}: missing explicit French`);
    if (!en.size) failures.push(`${key}: missing English`);
    if ([...fr.keys()].sort().join('|') !== [...en.keys()].sort().join('|')) failures.push(`${key}: variation structure`);
    for (const [variant, source] of fr) {
      variants++;
      const target = en.get(variant);
      if (typeof source.value !== 'string' || typeof target?.value !== 'string') {
        failures.push(`${key}/${variant}: invalid string unit`);
        continue;
      }
      if (source.value.trim() && !target.value.trim() && entry.extractionState !== 'stale') failures.push(`${key}/${variant}: empty English`);
      if (source.state !== 'translated' && entry.extractionState !== 'stale') failures.push(`${key}/${variant}: French not compiled`);
      if (target.state !== 'translated' && entry.extractionState !== 'stale') failures.push(`${key}/${variant}: English not translated`);
      if (formatSignature(source.value) !== formatSignature(target.value)) failures.push(`${key}/${variant}: format arguments`);
      if (markupSignature(source.value) !== markupSignature(target.value)) failures.push(`${key}/${variant}: markup or line breaks`);
      if (entry.shouldTranslate === false && source.value !== target.value) failures.push(`${key}/${variant}: non-translatable value changed`);
    }
  }
  return {keys: Object.keys(strings).length, variants, stale, failures};
}

export function assertFrenchPreserved(before, after) {
  const failures = [];
  if (Object.keys(before.strings).sort().join('\0') !== Object.keys(after.strings).sort().join('\0')) failures.push('Keys changed');
  for (const [key, source] of Object.entries(before.strings)) {
    const changed = after.strings[key];
    if (!changed) continue;
    const expected = materializedFrench(source, key);
    if (JSON.stringify(expected) !== JSON.stringify(changed.localizations?.fr)) failures.push(`${key}: French changed`);
    for (const [locale, value] of Object.entries(source.localizations ?? {})) {
      if (locale !== 'en' && locale !== 'fr' && JSON.stringify(value) !== JSON.stringify(changed.localizations?.[locale])) failures.push(`${key}: ${locale} changed`);
    }
    const metadata = ({localizations, ...rest}) => rest;
    if (JSON.stringify(metadata(source)) !== JSON.stringify(metadata(changed))) failures.push(`${key}: metadata changed`);
  }
  return failures;
}
