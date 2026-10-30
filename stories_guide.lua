-- ---------------------------------------------------------------------------
-- stories_guide.lua -- the "Where to find stories" text
--
-- Nothing is bundled or downloaded: this only says where free Z-code stories
-- live. Every title, author and file name below was checked against the IF
-- Archive's indexes (games/zcode/ and games/zcode/french/) on 2026-10-30;
-- the file names are the archive's, under ifarchive.org/if-archive/.
-- ---------------------------------------------------------------------------

local ARCHIVE = "ifarchive.org/if-archive/games/zcode/"

-- { title, author, file, en line, fr line }
local ENGLISH = {
    { "The Dreamhold", "Andrew Plotkin", "dreamhold.z8",
      "A tutorial adventure: the best first story to play.",
      "Une aventure-tutoriel : l'histoire idéale pour commencer." },
    { "Lost Pig", "Admiral Jota", "LostPig.z8",
      "Grunk the orc has lost a pig. Very funny. IF Competition 2007 winner.",
      "Grunk l'orque a perdu un cochon. Très drôle. Vainqueur de l'IF Competition 2007." },
    { "9:05", "Adam Cadre", "905.z5",
      "A short, ordinary morning — or is it? Five minutes to play.",
      "Un matin ordinaire, très court… ou pas. Cinq minutes de jeu." },
    { "Photopia", "Adam Cadre", "photopia.z5",
      "A short, moving story where the puzzles step aside.",
      "Une histoire courte et émouvante, presque sans énigmes." },
    { "Bronze", "Emily Short", "Bronze.zblorb",
      "Beauty and the Beast retold, with a helpful novice mode.",
      "La Belle et la Bête revisitée, avec un mode débutant." },
    { "Galatea", "Emily Short", "Galatea.zblorb",
      "One long conversation with a statue that came to life.",
      "Une longue conversation avec une statue devenue vivante." },
    { "Shade", "Andrew Plotkin", "shade.z5",
      "A brief, strange story in a small apartment.",
      "Une histoire brève et étrange dans un petit appartement." },
    { "Violet", "Jeremy Freese", "Violet.zblorb",
      "Write a thousand words of your thesis today. IF Competition 2008 winner.",
      "Écrire mille mots de sa thèse aujourd'hui. Vainqueur de l'IF Competition 2008." },
    { "Adventure", "Crowther & Woods, ported by Graham Nelson", "Advent.z5",
      "The 1976 original Colossal Cave, 350 points.",
      "La Colossal Cave originale de 1976, 350 points." },
    { "Spider and Web", "Andrew Plotkin", "Tangle.z5",
      "A captured spy tells his story. Clever, harder puzzles.",
      "Un espion capturé raconte. Ingénieux, énigmes plus difficiles." },
    { "Anchorhead", "Michael S. Gentry", "anchor.z8",
      "Long Lovecraftian horror in a gloomy New England town.",
      "Longue histoire d'horreur lovecraftienne dans une sinistre ville de Nouvelle-Angleterre." },
    { "Curses", "Graham Nelson", "curses.z5",
      "A big classic puzzle game that starts in a cluttered attic.",
      "Un grand classique à énigmes qui commence dans un grenier encombré." },
}

local FRENCH = {
    { "Aventure", "trad. Jean-Luc Pontico", "french/aventure.z5",
      "The original Adventure (Colossal Cave), in French.",
      "L'Adventure originale (Colossal Cave), en français." },
    { "Le butin du Capitaine Verdeterre", "Ryan Veeder, trad. Hugo Labrande",
      "french/Le_butin_du_Capitaine_Verdeterr.zblorb",
      "A pirate ship is sinking: grab the loot in time. Short and funny.",
      "Le navire coule : sauvez le butin à temps. Court et drôle." },
    { "Ombre", "Andrew Plotkin, trad.", "french/ombre.z5",
      "French translation of Shade.",
      "Traduction de Shade (voir plus bas)." },
    { "Kheper, une aventure égyptienne", "Benjamin Roux", "french/kheper.z8",
      "An Egyptian adventure.",
      "Une aventure en Égypte." },
    { "Initiation", "Benjamin Roux", "french/initiation.z8",
      "A sorcerer's apprentice, written for a French speed-IF.",
      "Les aventures d'un apprenti sorcier, écrit pour une speed-IF." },
    { "Sortir de la chambre", "Benjamin Roux", "french/sdlc.z5",
      "A locked-room puzzle: find a way out of the bedroom.",
      "Un huis clos : trouver comment sortir de la chambre." },
    { "Le Temple de Feu", "Eric Forgeot", "french/templefeu.z5",
      "An adventure in a faraway valley.",
      "Une aventure dans une vallée lointaine." },
}

local TEXT = {
    en = {
        title = "Where to find stories",
        intro = "Nothing comes with the game: download story files on a computer or with the reader's "
             .. "browser, then copy them into koreader/data/textadventure/ and tap Refresh. All the "
             .. "stories below are free; the line under each is its file on the IF Archive.",
        sites = "Where to look\n"
             .. "• IFDB — ifdb.org: the catalogue of interactive fiction, with reviews and ratings. "
             .. "Pick a story, then download its .z5, .z8 or .zblorb file.\n"
             .. "• IF Archive — ifarchive.org/indexes/if-archive/games/zcode/ (French stories: "
             .. ".../games/zcode/french/).\n"
             .. "• fiction-interactive.fr/jouer/ — the French community: contest games and news.\n"
             .. "Glulx stories (.ulx, .gblorb) are not Z-code and won't open here.",
        english = "Stories in English",
        french = "Stories in French",
    },
    fr = {
        title = "Où trouver des histoires",
        intro = "Le jeu n'en contient aucune : téléchargez des fichiers d'histoires sur un ordinateur "
             .. "ou avec le navigateur de la liseuse, copiez-les dans koreader/data/textadventure/ puis "
             .. "touchez Actualiser. Toutes les histoires ci-dessous sont gratuites ; la ligne sous "
             .. "chacune donne son fichier sur l'IF Archive.",
        sites = "Où chercher\n"
             .. "• fiction-interactive.fr/jouer/ — la communauté francophone : jeux des concours et actualités.\n"
             .. "• IFDB — ifdb.org : le catalogue de la fiction interactive, avec critiques et notes. "
             .. "Choisissez une histoire puis téléchargez son fichier .z5, .z8 ou .zblorb.\n"
             .. "• IF Archive — ifarchive.org/indexes/if-archive/games/zcode/french/ (en anglais : "
             .. ".../games/zcode/).\n"
             .. "Les histoires Glulx (.ulx, .gblorb) ne sont pas du Z-code et ne s'ouvrent pas ici.",
        english = "Histoires en anglais",
        french = "Histoires en français",
    },
}

local Guide = {}

local function section(head, list, lang)
    local out = { head }
    for _, s in ipairs(list) do
        out[#out + 1] = string.format("• %s — %s\n   %s\n   %s%s",
            s[1], s[2], lang == "fr" and s[5] or s[4], ARCHIVE, s[3])
    end
    return table.concat(out, "\n")
end

function Guide.title(lang) return (TEXT[lang] or TEXT.en).title end

-- French readers get the French stories first.
function Guide.text(lang)
    local t = TEXT[lang] or TEXT.en
    local l = TEXT[lang] and lang or "en"
    local en, fr = section(t.english, ENGLISH, l), section(t.french, FRENCH, l)
    local first, second = en, fr
    if l == "fr" then first, second = fr, en end
    return table.concat({ t.intro, t.sites, first, second }, "\n\n")
end

Guide.ENGLISH, Guide.FRENCH = ENGLISH, FRENCH
return Guide
