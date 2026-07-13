// @ts-check

/**
 * @template {number} [T=number]
 * @typedef {[from: number, to: number, category: T]} CategorizedUnicodeRange
 */

/**
 * @typedef {CategorizedUnicodeRange<0>} UnicodeRange
 */

/**
 * @typedef {string & { __tag: 'UnicodeDataEncoding' }} UnicodeDataEncoding
 *
 * Encoding for array of {@link UnicodeRange}, as a separator-free
 * sequence of variable-length quantities in the base36 alphabet;
 * each character carries 4 payload bits and a continuation bit.
 *
 * Each {@link UnicodeRange} packed as a pair of quantities:
 *
 * gap      = from - (previous to) - 1
 * padding  = to - from
 *
 * Notes:
 * - Ranges are sorted and never overlap, so the delta-encoded gap is
 *   always non-negative, and mostly a single character.
 * - The max value of a category is 23; https://www.unicode.org/reports/tr29/tr29-45.html#Table_Word_Break_Property_Values
 * - The longest range is 42,720; CJK UNIFIED IDEOGRAPH-20000..CJK UNIFIED IDEOGRAPH-2A6DF
 *
 * See `scripts/lib/encoding.js` for the encoder.
 */

/**
 * @template {number} [T=number]
 * @param {UnicodeDataEncoding} data
 * @param {string} [cats='']
 * @returns {Array<CategorizedUnicodeRange<T>>}
 */
export function decodeUnicodeData(data, cats = '') {
  let buf = /** @type {Array<CategorizedUnicodeRange<T>>} */([])
    , len = data.length
    , i = 0
    , j = 0
    , p = -1;
  let read = () => {
    let n = 0, shift = 0, d;
    do {
      d = parseInt(data[i++], 36);
      n += (d & 15) << shift;
      shift += 4;
    } while (d & 16);
    return n;
  };
  while (i < len) {
    let from = p + 1 + read();
    p = from + read();
    buf.push([from, p, /** @type {T} */ (cats ? parseInt(cats[j++], 36) : 0)]);
  }
  return buf;
}

/**
 * @template {object} Ext
 * @typedef {{
 *   segment: string,
 *   index: number,
 *   input: string,
 * } & Ext} SegmentOutput
 */

/**
 * @template {object} T
 * @typedef {IterableIterator<SegmentOutput<T>>} Segmenter
 */

/**
 * @typedef {[starts: Uint32Array, ends: Uint32Array]} UnicodeRangeTable
 *
 * Flat, binary-searchable range table. `starts[i]` holds the first
 * codepoint of the i-th range, and `ends[i]` packs its last codepoint
 * and category as `end << 5 | category`.
 *
 * The 5-bit category fits any break property; the largest category
 * value is 23.
 */

/**
 * Category of the range containing the given codepoint.
 *
 * @param {number} cp
 * @param {Uint32Array} starts sorted, non-overlapping range starts
 * @param {Uint32Array} ends packed `end << 5 | category`, parallel to `starts`
 * @return {number} category of the containing range, or 0 if no match
 */
export function findUnicodeRangeCategory(cp, starts, ends) {
  let lo = 0, hi = starts.length - 1;
  while (lo <= hi) {
    let mid = lo + hi >>> 1
      , end = ends[mid];
    if (cp < starts[mid]) hi = mid - 1;
    else if (cp > end >>> 5) lo = mid + 1;
    else return end & 31;
  }
  return 0;
}

/**
 * Decode {@link UnicodeDataEncoding} into a membership test table for
 * {@link findUnicodeRangeCategory}; every range takes category 1, so a
 * match is truthy and a miss is 0.
 *
 * @param {UnicodeDataEncoding} data
 * @return {UnicodeRangeTable}
 */
export function decodeUnicodeFlatData(data) {
  let ranges = decodeUnicodeData(data)
    , starts = new Uint32Array(ranges.length)
    , ends = new Uint32Array(ranges.length);
  for (let i = 0; i < ranges.length; i++) {
    starts[i] = ranges[i][0];
    ends[i] = ranges[i][1] << 5 | 1;
  }
  return [starts, ends];
}
