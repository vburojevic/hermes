# Third-party notices

The app bundles these libraries in `App/Resources/RenderKit` to draw a reply's diagrams and
formulas on the device (`docs/chat.md` §3b). They run in a hidden web view that loads nothing from
the network. Their full licence texts ship beside them.

## Mermaid 11.17.2

Diagrams. <https://github.com/mermaid-js/mermaid>, `mermaid.min.js`, MIT
(`mermaid-LICENSE.txt`):

> Copyright (c) 2014 - 2022 Knut Sveidqvist
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or
> substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
> NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Its build includes, among others, under their own licences:

| Library | Licence |
|---|---|
| DOMPurify 3.4.12, (c) Cure53 and other contributors | Apache 2.0 or MPL 2.0 |
| Lodash (lodash-es 4.18.1), OpenJS Foundation and contributors | MIT |
| d3 and its modules, Mike Bostock | ISC |
| d3-sankey, Mike Bostock | BSD 3-Clause |
| dagre-d3-es, cytoscape, cytoscape-cose-bilkent, cytoscape-fcose | MIT |
| KaTeX, marked, khroma, dayjs, roughjs, stylis, uuid, ts-dedent, @braintree/sanitize-url, @iconify/utils, langium | MIT |
| chevrotain | Apache 2.0 |
| Promises/A+ thenable (Ralf S. Engelschall), jQuery's event object, bezier and spring functions (Gaetan Renaudeau, Koen Bok) inside cytoscape | MIT |

## MathJax 3.2.2

Display math. <https://github.com/mathjax/MathJax>, `tex-svg-full.js`, Apache License 2.0
(`mathjax-LICENSE.txt`). Copyright (c) 2009-2022 The MathJax Consortium. Used unmodified; the app
configures it from `drawn-blocks.js`. Its full build includes the mhchem extension, Copyright (c)
2015-2021 Martin Hensel, Apache License 2.0.
