// Lista de frases habladas (capítulos, decisiones y tutorial) para generar las voces neuronales.
// Uso: node tools/voice_lines.mjs > ../investigacion/voces/frases.json
import fs from 'node:fs';
import {CHAPTERS, DECISIONS} from '../dist/story.js';
import {sentences, speechText, clipId} from '../dist/voice.js';
const app = fs.readFileSync(new URL('../dist/app.js', import.meta.url), 'utf8');
const unq = x => x.replace(/\\'/g, "'");
const tutorial = [...app.matchAll(/\{title: '((?:[^'\\]|\\.)*)', text: '((?:[^'\\]|\\.)*)'/g)].map(m => ['minister', unq(m[2])]);
const lines = [...CHAPTERS.map(c => [c.speaker, c.text]), ...DECISIONS.map(d => [d.person, d.body]), ...tutorial];
const seen = new Set(), out = [];
for (const [person, text] of lines) for (const s of sentences(text)) {
  const id = clipId(person, s);
  if (!seen.has(id)) { seen.add(id); out.push({id, person, text: speechText(s)}); }
}
process.stdout.write(JSON.stringify(out, null, 1) + '\n');
console.error(`${lines.length} diálogos, ${out.length} frases.`);
