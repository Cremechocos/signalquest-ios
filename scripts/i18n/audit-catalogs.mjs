#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {auditCatalog,CATALOG_PATHS,BUNDLE_PLISTS} from './catalog-contract.mjs';

const root=path.resolve(process.argv[2]??path.join(path.dirname(fileURLToPath(import.meta.url)),'../..'));
let failed=false;
for(const relative of CATALOG_PATHS){
  const report=auditCatalog(JSON.parse(fs.readFileSync(path.join(root,relative),'utf8')));
  console.log(`${relative}: ${report.keys} keys, ${report.variants} FR/EN variants, ${report.stale} historical entries, ${report.failures.length} failures`);
  for(const failure of report.failures)console.error(failure);
  failed ||= report.failures.length>0;
}
for(const relative of BUNDLE_PLISTS){
  const plist=fs.readFileSync(path.join(root,relative),'utf8');
  if(!/<key>CFBundleDevelopmentRegion<\/key>\s*<string>en<\/string>/.test(plist)){
    console.error(`${relative}: runtime fallback must be en`);failed=true;
  }
}
const project=fs.readFileSync(path.join(root,'project.yml'),'utf8');
if(!/developmentLanguage:\s*fr\b/.test(project)||!/CFBundleDevelopmentRegion:\s*en\b/.test(project)){
  console.error('project.yml must retain French extraction and regenerate the Widget English fallback');failed=true;
}
if(failed)process.exitCode=1;
else console.log('FR/EN resource contracts and English bundle fallback configuration passed.');
