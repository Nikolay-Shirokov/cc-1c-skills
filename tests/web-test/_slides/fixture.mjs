// Fixture for 28-slides: a two-slide module for `run.mjs play` / `run.mjs preview`.
// no tts: the regress runs play with --no-narration and preview (no TTS service calls)
export const theme = { accent: '#2f9fd8' };

export default [
  { layout: 'title', kicker: 'web-test', title: 'Проверка слайдов', speech: 'Проверка слайдов.' },
  {
    layout: 'cards', title: 'Две карточки',
    cards: [{ title: 'Первая', items: ['пункт'] }, { title: 'Вторая', items: ['пункт'] }],
    steps: [{ show: 0, speech: 'Первая.' }, { show: 1, speech: 'Вторая.' }],
  },
];
