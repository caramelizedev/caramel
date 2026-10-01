#include <stddef.h>
#include "../../../lib/lexbor/src/ext/lexbor.c"

_Static_assert(sizeof(lxb_dom_node_t) == CORRETTO_NODE_SIZE,
               "Corretto DOM node layout differs from Lexbor");
_Static_assert(offsetof(lxb_dom_node_t, ns) == CORRETTO_NAMESPACE_OFFSET,
               "Corretto namespace offset differs from Lexbor");
_Static_assert(sizeof(lxb_dom_element_t) == CORRETTO_ELEMENT_SIZE,
               "Corretto DOM element layout differs from Lexbor");
_Static_assert(sizeof(lxb_html_template_element_t) == CORRETTO_TEMPLATE_SIZE,
               "Corretto template layout differs from Lexbor");
_Static_assert(offsetof(lxb_html_template_element_t, content) == CORRETTO_CONTENT_OFFSET,
               "Corretto template content offset differs from Lexbor");
_Static_assert(LXB_NS_HTML == CORRETTO_HTML_NAMESPACE,
               "Corretto HTML namespace differs from Lexbor");
_Static_assert(LXB_DOM_NODE_TYPE_DOCUMENT_FRAGMENT == CORRETTO_DOCUMENT_FRAGMENT,
               "Corretto document fragment type differs from Lexbor");
