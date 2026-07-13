// Grapheme segmentation is provided by unicode-segmenter 0.17.0.
// Source: https://github.com/cometkim/unicode-segmenter
// License: MIT, see LICENSE.

import { Segmenter } from './intl-adapter.js'

const intl = globalThis.Intl || (globalThis.Intl = {})

if (!Object.prototype.hasOwnProperty.call(intl, 'Segmenter')) {
  Object.defineProperty(intl, 'Segmenter', {
    value: Segmenter,
    enumerable: false,
    writable: true,
    configurable: true
  })
}
