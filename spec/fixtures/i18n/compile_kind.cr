require "../../../src/caramel/i18n"

Caramel.locale "en", {
  books: {count: "Books"},
}

Caramel.locale "fr", {
  books: {count: {one: "Livre", many: "Livres", other: "Livres"}},
}

Caramel.locales default: "en"
