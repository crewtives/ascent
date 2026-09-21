# Changelog

All notable changes to Ascent are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Saber que hay una versión más nueva.** Un addon no puede hacer peticiones de red, así que la única fuente
  posible son los demás jugadores: Ascent anuncia su versión por el canal de addons a la hermandad y al grupo,
  y escucha las de los demás. No se cree a uno solo —el contenido de esos mensajes lo escribe el cliente ajeno
  y se puede falsificar—, así que hacen falta tres jugadores distintos anunciando la misma versión posterior
  antes de decir nada, y lo dice una vez por sesión. Envía muy por debajo de lo que el cliente permite, no
  reintenta un rechazo y nunca responde a un anuncio ajeno con otro.
- **`/ascent changelog`**, que muestra qué cambió sin salir del juego, con la versión en ejecución arriba y
  como texto seleccionable. Se genera desde este mismo archivo al empaquetar, así que no puede contar otra
  cosa.
- **Aviso al cambiar de versión.** Al entrar, el addon dice si se actualizó. Y si se volvió a una versión
  anterior, dice lo que hasta ahora pasaba en silencio: el historial escrito por la versión posterior queda
  **apartado, no borrado**, porque una migración sólo camina hacia adelante.
- **Un interruptor** en Interface → AddOns para apagarlo, que silencia las dos mitades: deja de avisar y deja
  de anunciar.

## [0.1.0] - 2026-09-21

First public build, and an early beta rather than a finished thing: it has been played far less than
it has been tested. Targets Classic Era 1.15.x (`11509`) and Burning Crusade 2.5.x (`20506`) from a
single TOC.

If something looks wrong, `/ascent copy` hands you the diagnostics as selectable text - that is the
only way anything from your game can reach the author, since an addon cannot make a network request.

### Added

- **Experience attribution.** Every gain is reconciled against the client's authoritative experience
  delta, so the sources add up to exactly the experience of the level. Quests, creature kills and
  exploration are classified from the client's own messages; what the client reported but did not
  explain is kept in a bucket that says so, including the part of a level the addon was not installed
  for. Gains that cross a level-up are split across the two levels.
- **The rested bonus, read rather than inferred.** The bonus is taken from the figure the client puts
  in parentheses on the kill itself, not from watching the reserve drain.
- **The group bonus and the raid penalty**, shown as portions already inside the amount rather than as
  extra experience.
- **Where it happened.** Each gain is sealed with the place it was earned in — open world, dungeon,
  raid, battleground, arena — at the instant the increase is observed. What the client could not name
  is counted as unrecorded and reported as a share of the level, never imputed.
- **Level history.** A record per level and per character: duration, experience by source and by place,
  rested portion, sessions crossed, combat aggregates. Versioned on disk, migrated across schema
  changes, and bounded by an explicit retention policy.
- **Combat metrics per level.** Health and resource on leaving combat, deaths and the time lost to
  them, time in combat versus downtime, damage done and taken, healing, and efficiency per kill.
- **Ability ranking.** What was actually pressed, ranked by use, with auto-attacks kept separate so the
  percentages are answering one question at a time.
- **Pending experience.** What the quest log would pay out right now, adjusted to the character's
  level, with the provenance of each figure stated and quests the client cannot price counted rather
  than hidden. Quest names come from one account-wide directory, so every surface calls the same quest
  the same thing.
- **Projections.** Experience per hour for the level and the session, time to the next level, estimated
  kills remaining, and the level's completion with and without the rested bonus.
- **A report you can actually send.** `/ascent copy`, and a button on the options panel, open the
  diagnostics as selectable text —
  headed by the addon's build, the client's flavour and the interface language — because an addon
  cannot make a network request and chat text cannot be selected. It carries no character name and
  no realm, and it is editable before you paste it.
- **Segmented bar.** An independent bar — Blizzard's is left alone — where each segment is a source,
  with a rested marker, a separate channel for pending experience, a breakdown tooltip, configurable
  text, and a saved position that is clamped back onto the visible screen.
- **Level report panel** with five tabs: Sources, Combat, Abilities, Pending and History, the last one
  selectable level by level and comparable against the level before.
- **Six skins** — Tabard, Cartographer, Stormwind, Glass, Telemetry, Phantom — each covering bar and
  panel alike, with per-axis tuning, per-source colours, a high-contrast mode and a motion scale that
  reaches zero.
- **Options** in `/ascent options` and under Interface → AddOns, persisted per account, with a live
  preview bar and a demo mode that steps every visual state.
- **Commands**: `show`, `hide`, `panel`, `summary`, `pending`, `options`, `demo`, `reset confirm`,
  `debug` and `evidence`.
- **Evidence recording** (`/ascent evidence on`), which writes a session to the saved variables file
  for later reading instead of to chat.
- **Graceful stop** at maximum level and when experience gain is disabled.
- **Flavour compatibility** resolved at runtime: only the collectors the client supports are
  registered, and `/ascent debug` reports which capabilities are present and which are not.

[0.1.0]: https://github.com/crewtives/ascent/releases/tag/v0.1.0
