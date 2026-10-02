require "../../../src/caramel/i18n"

Caramel.locale "en", {
  home: {greeting: "Hello, %{user}!"},
}

Caramel.locale "fr", {
  home: {greeting: "Bonjour, %{name} !"},
}

Caramel.locales default: "en"
