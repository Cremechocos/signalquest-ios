import assert from 'node:assert/strict';
import test from 'node:test';
import {auditCatalog, assertFrenchPreserved, formatSignature, markupSignature, materializedFrench} from './catalog-contract.mjs';
const unit=(value)=>({stringUnit:{state:'translated',value}});
const catalog=(fr='Bonjour',en='Hello')=>({sourceLanguage:'fr',strings:{Bonjour:{localizations:{fr:unit(fr),en:unit(en)}}}});

test('French editorial source and explicit FR/EN are required',()=>{
  assert.deepEqual(auditCatalog(catalog()).failures,[]);
  assert.match(auditCatalog({...catalog(),sourceLanguage:'en'}).failures[0],/source/);
  const missing=catalog();delete missing.strings.Bonjour.localizations.fr;
  assert.ok(auditCatalog(missing).failures.some((f)=>f.includes('missing explicit French')));
});
test('positional reordering retains printf contracts',()=>{
  assert.equal(formatSignature('%@ %lld %%'),formatSignature('%2$lld %% %1$@'));
  assert.equal(formatSignature('%1$@ %1$@'),formatSignature('%1$@'));
  assert.equal(formatSignature('100 %%'),'[]');
});
test('printf types, lengths and argument positions cannot change',()=>{
  assert.notEqual(formatSignature('%@'),formatSignature('%lld'));
  assert.notEqual(formatSignature('%lld'),formatSignature('%d'));
  assert.notEqual(formatSignature('%@ %lld'),formatSignature('%1$lld %2$@'));
  assert.ok(auditCatalog(catalog('%lld relevés','%@ measurements')).failures.some((f)=>f.includes('format')));
});
test('Markdown emphasis, links, code and newlines survive translation',()=>{
  assert.equal(markupSignature('**Bonjour** [a](https://example.invalid)\n`x`'),markupSignature('**Hello** [b](https://example.invalid)\n`x`'));
  assert.notEqual(markupSignature('**Hello**'),markupSignature('Hello'));
  assert.notEqual(markupSignature('[a](https://example.invalid/a)'),markupSignature('[b](https://example.invalid/b)'));
  assert.notEqual(markupSignature('a\nb'),markupSignature('a b'));
});
test('plural branches are compared independently',()=>{
  const c=catalog();
  c.strings.Bonjour.localizations={
    fr:{variations:{plural:{one:unit('%lld point'),other:unit('%@ points')}}},
    en:{variations:{plural:{one:unit('%@ point'),other:unit('%lld points')}}},
  };
  assert.equal(auditCatalog(c).failures.filter((f)=>f.includes('format')).length,2);
  delete c.strings.Bonjour.localizations.en.variations.plural.one;
  assert.ok(auditCatalog(c).failures.some((f)=>f.includes('structure')));
});
test('empty active English fails; intentionally empty and stale values remain allowed',()=>{
  assert.ok(auditCatalog(catalog('Bonjour','')).failures.some((f)=>f.includes('empty')));
  assert.deepEqual(auditCatalog(catalog('','')).failures,[]);
  const stale=catalog('à ','');stale.strings.Bonjour.extractionState='stale';
  assert.deepEqual(auditCatalog(stale).failures,[]);
});
test('translation state must be complete for active strings',()=>{
  const c=catalog();c.strings.Bonjour.localizations.en.stringUnit.state='needs_review';
  assert.ok(auditCatalog(c).failures.some((f)=>f.includes('not translated')));
});
test('existing French new units become compilable without changing text or variants',()=>{
  const before=catalog();before.strings.Bonjour.localizations.fr.stringUnit.state='new';
  assert.ok(auditCatalog(before).failures.some((f)=>f.includes('French not compiled')));
  const after=structuredClone(before);after.strings.Bonjour.localizations.fr=materializedFrench(before.strings.Bonjour,'Bonjour');
  assert.deepEqual(assertFrenchPreserved(before,after),[]);
  assert.deepEqual(auditCatalog(after).failures,[]);
});
test('non-translatable technical strings must stay identical',()=>{
  const c=catalog('RSRP','RSRQ');c.strings.Bonjour.shouldTranslate=false;
  assert.ok(auditCatalog(c).failures.some((f)=>f.includes('non-translatable')));
});
test('materialising implicit French preserves all existing metadata and languages',()=>{
  const before={sourceLanguage:'fr',strings:{Bonjour:{extractionState:'stale',comment:'Keep',localizations:{en:unit('Hello'),de:unit('Hallo')}}}};
  const after=structuredClone(before);after.strings.Bonjour.localizations.fr=unit('Bonjour');
  assert.deepEqual(assertFrenchPreserved(before,after),[]);
  after.strings.Bonjour.localizations.de=unit('Other');
  assert.ok(assertFrenchPreserved(before,after).some((f)=>f.includes('de changed')));
});
test('a French text change, key deletion or metadata rewrite is rejected',()=>{
  const before=catalog(),after=catalog('Salut','Hello');
  assert.ok(assertFrenchPreserved(before,after).some((f)=>f.includes('French changed')));
  const removed=structuredClone(before);delete removed.strings.Bonjour;
  assert.ok(assertFrenchPreserved(before,removed).includes('Keys changed'));
  const metadata=structuredClone(before);metadata.strings.Bonjour.shouldTranslate=false;
  assert.ok(assertFrenchPreserved(before,metadata).some((f)=>f.includes('metadata changed')));
});
