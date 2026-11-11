# Other web pages

A session can show web pages that are not 1C: an adjacent system in a video about an integration (1C → the other
system → 1C, one video), or a video with no 1C at all (slides and a web product). Recording, slides and captions
work on any page; switching between pages is `setActiveContext`, the video follows the page on screen.

## A page next to 1C

```js
await web.open('crm', 'https://crm.example.ru/orders');   // a tab in the session's window; the 1C page becomes 'main'
await setActiveContext('main');                           // back to 1C
await clickElement('Провести и закрыть');
await showCaption('', { speech: 'Заказ уходит в CRM…' });
await setActiveContext('crm');                            // the video goes on in the other system
const crm = getPage();                                    // its actions — Playwright
await crm.getByRole('button', { name: 'Обновить' }).click();
await web.highlight(crm.getByText('Заказ 000123'));
await showCaption('', { speech: '…и появляется здесь.' });
await web.unhighlight();
await setActiveContext('main');
```

- `web.open(name, url, { ready, login })` — open a page as a context `name`; `ready` — a CSS selector to wait for
  (pages that keep loading after `load`); again with the same name — go to `url` there. No 1C steps on it.
- Actions on the page are Playwright: `getPage()` while its context is active (`click`, `fill`, `getByText`,
  `waitForTimeout` for a pause). The 1C functions (`clickElement`, `fillFields`, `highlight(text)`, `wait`) are
  for 1C pages.
- `web.highlight(locator)` — a frame around an element, as `highlight` draws on 1C; `web.unhighlight()` removes it.
- `web.mask([...])` — hide parts of the active page in the video: CSS selectors and `{ text: '…' }` (the element
  holding the text — its neighbours in a row stay; a whole row or block — by a selector). Holds after the page
  changes or reloads: names, e-mails, service banners.

## A video without 1C

```bash
node $RUN start https://portal.example.ru/analysis --web    # a visible window with the page, no 1C
node $RUN exec video.js
```

`start` / `run` with `--web [--ready=<css>] [--login=<file>]` open the page instead of 1C; the script is the usual
one — slides, `hideSlide`, actions on `getPage()`, `showCaption('', { speech })`, slides again.

## Logging in

- **By hand** (the default): the session's window is visible — open the page, log in, then run the script that
  records. The login holds for the whole session.
- **A saved login** for repeated recordings: after logging in, `await web.saveLogin('debug/portal-login.json')`;
  later `--login=debug/portal-login.json` (or `web.open(name, url, { login })`). The file holds that site's
  cookies and stored tokens — it is the user's session: keep it out of git (`debug/` is ignored), do not send it
  on. When the site's session expires, log in by hand and save again.
