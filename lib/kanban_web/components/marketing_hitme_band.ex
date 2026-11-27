defmodule KanbanWeb.MarketingHitmeBand do
  @moduledoc """
  The home page band that promotes the half-day proof-of-concept session and
  links to the public `/HitMe` page (`KanbanWeb.PageController.hit_me/2`).
  Lives in its own module so `KanbanWeb.MarketingComponents` does not grow
  past the module-size guideline.

  It is a small copy of the `/HitMe` flyer card: the navy card, the tilted
  sticker, the pixel-font kicker and the cyan button, so a visitor
  recognises the offer when they land on its page. Every string is one the
  `/HitMe` page already uses, so the band needs no translations of its own.

  The card is navy in both themes, like the flyer, so it uses the
  `--hitme-*` tokens, which are the same in light and dark. Render inside
  the `.stride-marketing` CSS scope so those tokens, `--line` and the
  `.hitme-*` classes resolve.
  """
  use KanbanWeb, :html

  @doc "Renders the half-day session band: sticker, kicker, heading, one sentence and a link to `/HitMe`."
  def marketing_hitme_band(assigns) do
    ~H"""
    <section
      class="px-5 py-8 md:px-16 md:py-10"
      style="border-bottom: 1px solid var(--line);"
      aria-labelledby="hitme-band-heading"
      data-hitme-band
    >
      <div class="hitme-promo">
        <img
          src={~p"/images/marketing/hitme-sticker.png"}
          alt=""
          width="504"
          height="504"
          loading="lazy"
          class="hitme-promo-sticker"
        />
        <div class="hitme-promo-copy">
          <p class="hitme-kicker hitme-promo-kicker">{gettext("Stride with us")}</p>
          <h2 id="hitme-band-heading" class="hitme-promo-heading">
            {gettext("Half-day AI proof-of-concept sessions")}
          </h2>
          <p class="hitme-promo-lead">
            {gettext(
              "In half a day: your backlog and agents set up, part of your proof of concept delivered, and your team is ready."
            )}
          </p>
        </div>
        <.link navigate={~p"/HitMe"} class="hitme-button hitme-promo-button" data-hitme-link>
          {gettext("Book a half-day session")}
          <.icon name="hero-arrow-right" class="w-4 h-4" />
        </.link>
      </div>
    </section>
    """
  end
end
