// Что проверяем: стенд жив — пользователь входит, рабочий стол без ошибок, ключевой раздел на месте.
//
// Приём — smoke-тест. Идёт первым (папка 00-), быстрый, без записи данных. Тег smoke в
// webtest.config.mjs отнесён к severity critical: в отчёте его падение видно сразу и отсекает
// разбор остальных — если не открылся рабочий стол, остальные упадут по той же причине.
// Контекст не указан — тест идёт под defaultContext (admin).
//
// Как сделать так же: вход + переход в главный раздел решения + одно утверждение о составе
// раздела. Никаких документов — smoke должен быть секундным.

export const name = 'Вход и раздел «Заявки»';
export const tags = ['smoke'];

export default async function({ getFormState, navigateSection, assert }) {
  assert.noErrors(await getFormState(), 'рабочий стол открывается без ошибок');
  const nav = await navigateSection('Заявки');
  assert.includes(nav.commands.flat(), 'Заявки на расход', 'в разделе есть список заявок');
}
