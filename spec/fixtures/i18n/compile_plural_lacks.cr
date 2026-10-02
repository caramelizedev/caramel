require "../../../src/caramel/i18n"

Caramel.locale "en", {
  books: {count: {one: "%{count} book", other: "%{count} books"}},
}

Caramel.locale "fr", {
  books: {count: {one: "%{count} livre", other: "%{count} livres"}},
}

Caramel.locales default: "en"
