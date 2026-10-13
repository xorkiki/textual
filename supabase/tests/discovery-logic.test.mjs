// Pure Edge Function logic. Offline: no provider or database requests.
// Run with Node 22.18+ (TypeScript type stripping): node supabase/tests/discovery-logic.test.mjs
import assert from 'node:assert/strict';
const d = await import('../functions/discovery-refresh/discovery.ts');
let checks = 0;
const ok = (value, message) => { assert.ok(value, message); checks++; };
const eq = (a, b, message) => { assert.deepEqual(a, b, message); checks++; };

// Identity keys
eq(d.titleKey('The Hobbit: Or There and Back Again'), 'hobbit');
eq(d.titleKey('Onyx Storm (The Empyrean, #3)'), 'onyx storm');
eq(d.authorKey('J.R.R. Tolkien'), d.authorKey('J. R. R. Tolkien'));
ok(d.authorKey('John Green') !== d.authorKey('Jane Green'));
eq(d.splitAuthors('Liz Moore and Jo Smith'), ['Liz Moore', 'Jo Smith']);
eq(d.normalizedISBN('978-0-385-55055-0'), '9780385550550');
eq(d.normalizedISBN('038555055X'), '038555055X');
eq(d.normalizedISBN('12345'), null);
eq(d.isbnFromArtwork('https://is1-ssl.mzstatic.com/image/thumb/Publication211/v4/98/75/fe/x/9780385550550.d.jpg/100x152bb.png'), '9780385550550');
eq(d.isbnFromArtwork('https://is1-ssl.mzstatic.com/image/thumb/Publication/v4/abc/cover.jpg/100x152bb.png'), null);

// Work matching is exact on main title and author identity, never "similar"
const doc = { key: '/works/OL123W', title: 'Verity', author_name: ['Colleen Hoover'], cover_i: 9,
    editions: { docs: [{ title: 'Verity', language: ['eng'], cover_i: 10, isbn: ['9781538724743'], publish_date: ['Oct 5, 2021'] }] } };
ok(d.sameWork('VERITY', 'Colleen Hoover', doc));
ok(!d.sameWork('Verity', 'Someone Else', doc), 'different author');
ok(!d.sameWork('Verity Lane', 'Colleen Hoover', doc), 'similar title is not the same work');
ok(!d.sameWork('', 'Colleen Hoover', doc));

// Doc conversion prefers the English edition and rejects incomplete records
const book = d.bookFromDoc(doc);
eq(book.provider_id, 'OL123W');
eq(book.cover_url, 'https://covers.openlibrary.org/b/id/10-L.jpg');
eq(book.published_date, '2021-10-05');
eq(book.isbns, ['9781538724743']);
eq(book.work_key, 'openlibrary:OL123W');
eq(d.bookFromDoc({ ...doc, cover_i: undefined, editions: undefined }), null, 'no cover');
eq(d.bookFromDoc({ ...doc, author_name: [] }), null, 'no author');
eq(d.bookFromDoc({ ...doc, key: '/books/OL1M' }), null, 'edition key is not a work');
eq(d.bookFromDoc({ ...doc, readinglog_count: 2 }, 10), null, 'below quality threshold');
const translated = d.bookFromDoc({ key: '/works/OL9W', title: 'Cien años de soledad', author_name: ['Gabriel García Márquez'], cover_i: 5,
    editions: { docs: [{ title: 'One Hundred Years of Solitude', language: ['eng'], cover_i: 6 }] } });
eq(translated.title, 'One Hundred Years of Solitude');

// Publish dates: unambiguous full dates only
eq(d.parsePublishDate('2025-01-21'), '2025-01-21');
eq(d.parsePublishDate('April 8, 2025'), '2025-04-08');
eq(d.parsePublishDate('19 Feb 2025'), '2025-02-19');
eq(d.parsePublishDate('2025'), null);
eq(d.parsePublishDate('21/10/2025'), null);
eq(d.parsePublishDate('Feb 30, 2025'), null);

// Recent releases use real years and never future dates
const now = new Date(Date.UTC(2026, 9, 12));
const release = (year, date = null) => ({ ...book, first_published_year: year, published_date: date });
ok(d.isRecentRelease(release(2026, '2026-09-29'), now));
ok(d.isRecentRelease(release(2025), now));
ok(!d.isRecentRelease(release(2023), now), 'outdated');
ok(!d.isRecentRelease(release(null), now), 'unknown year');
ok(!d.isRecentRelease(release(2026, '2026-12-01'), now), 'future date');
ok(!d.isRecentRelease(release(2025, '2025-01-02'), now), 'older than 18 months');

// Deduplication keeps the first work and merges exact duplicate work records only
const a = { ...book, work_key: 'openlibrary:OL1W', title: 'Same', author: 'Writer' };
const dup = { ...book, work_key: 'openlibrary:OL2W', title: 'Same', author: 'Writer' };
const other = { ...book, work_key: 'openlibrary:OL3W', title: 'Same', author: 'Other Writer' };
eq(d.uniqueWorks([a, a, dup, other]).map(b => b.work_key), ['openlibrary:OL1W', 'openlibrary:OL3W']);
eq(d.interleave([[1, 2, 3], [4], [5, 6]], 5), [1, 4, 5, 2, 6]);

// Trending: one normalized score per source family; multi-source books rise
const work = id => ({ ...book, work_key: `openlibrary:${id}`, provider_id: id });
const entry = (source, rank, listSize, list) => ({ source, sourceID: `${source}${rank}`, list, rank, listSize, title: '', author: '', isbn: null });
const ranked = d.rankTrending([
    { book: work('A'), entries: [entry('apple', 1, 100, 'Fiction')] },
    { book: work('B'), entries: [entry('apple', 10, 100, 'Fiction'), entry('nyt', 2, 15, 'Hardcover')] },
    { book: work('C'), entries: [entry('nyt', 1, 15, 'Hardcover'), entry('nyt', 1, 15, 'Combined')] },
]);
eq(ranked.map(r => r.book.provider_id), ['B', 'A', 'C']);
eq(ranked[0].sources, ['apple', 'nyt']);
eq(ranked[2].score, 1, 'many lists in one family still count once');
// Variety: a third consecutive pick from one list yields to a close alternative
const many = d.rankTrending([
    ...['1', '2', '3'].map((id, i) => ({ book: work(id), entries: [entry('apple', i + 1, 50, 'Romance')] })),
    { book: work('4'), entries: [entry('apple', 4, 50, 'History')] },
]);
eq(many.map(r => r.book.provider_id), ['1', '2', '4', '3']);

// Google fallback: exact title and author identity, larger cover, no page curl
const volume = { id: 'abc_DEF-1', volumeInfo: { title: 'The French Illusion', authors: ['John Grisham'], publishedDate: '2026-09-29',
    industryIdentifiers: [{ type: 'ISBN_13', identifier: '9780385550550' }],
    imageLinks: { thumbnail: 'http://books.google.com/books/content?id=abc_DEF-1&printsec=frontcover&img=1&zoom=1&edge=curl&source=gbs_api' } } };
const google = d.bookFromGoogleVolume(volume, 'THE FRENCH ILLUSION', 'John Grisham');
eq(google.provider, 'google');
eq(google.work_key, 'google:abc_DEF-1');
eq(google.published_date, '2026-09-29');
eq(google.first_published_year, 2026);
ok(google.cover_url.startsWith('https://books.google.com/') && google.cover_url.includes('fife=w800') && !google.cover_url.includes('edge='));
eq(d.bookFromGoogleVolume(volume, 'The French Connection', 'John Grisham'), null, 'different title');
eq(d.bookFromGoogleVolume(volume, 'The French Illusion', 'Someone Else'), null, 'different author');
eq(d.bookFromGoogleVolume({ ...volume, id: 'bad/id' }, 'The French Illusion', 'John Grisham'), null);
eq(d.googleCoverURL('https://evil.example/x.jpg'), null);

// Image headers
const png = new Uint8Array(24); png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
new DataView(png.buffer).setUint32(16, 320); new DataView(png.buffer).setUint32(20, 480);
eq(d.imageSize(png), { width: 320, height: 480 });
const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x11, 0x08, 0x01, 0xf4, 0x01, 0x4a, 0x03, 0x00, 0x00, 0x00, 0x00]);
eq(d.imageSize(jpeg), { width: 330, height: 500 });
eq(d.imageSize(jpeg.slice(0, 9)), null, 'incomplete header');
eq(d.imageSize(new Uint8Array([0x47, 0x49, 0x46, 0x38])), null, 'unsupported format');
ok(d.isUsableCover({ width: 330, height: 500 }));
ok(!d.isUsableCover({ width: 1, height: 1 }), 'placeholder pixel');
ok(!d.isUsableCover({ width: 600, height: 100 }), 'banner');
ok(!d.isUsableCover(null));

// Explore facets are unique and span subjects, eras, and literary origins
const ids = d.EXPLORE_FACETS.map(f => f.id);
eq(new Set(ids).size, ids.length);
for (const required of ['literary', 'poetry', 'philosophy', 'science', 'history', 'memoir', 'classics', 'translated', 'pre-1900', 'contemporary'])
    ok(ids.includes(required), required);

console.log(`${checks} discovery logic checks passed (offline).`);
