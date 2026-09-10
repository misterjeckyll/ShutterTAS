-- Frame counter is updated every engine frame.
-- Game time is currently disabled because GetTimeSeconds()
-- is exposed as a TrivialObjectValue in this UE4SS build.

--------------------------------------------------------
-- TAS STATE
--------------------------------------------------------
-- Le HUD n'a pas besoin d'etre rafraichi a chaque frame.
-- Chaque ligne qui change coute un FText, et FText::construct est la
-- fonction qui plante le plus souvent dans les dumps. On affiche donc
-- a ~7 Hz. TAS.Frame, lui, continue de compter chaque frame.
HUD_REFRESH_INTERVAL = 8

-- Frames minimum entre deux FindFirstOf quand le controleur est absent.
CONTROLLER_SEARCH_INTERVAL = 60

--------------------------------------------------------
-- CONFIGURATION
--
-- Sert a isoler l'origine d'un crash : on desactive une section,
-- on relance, on regarde si le crash disparait.
--
-- key_hooks enregistre un callback sur ~158 touches, qui ecrivent
-- dans l'UMG depuis le contexte d'input, hors du tick. C'est le
-- comportement le plus invasif du mod : le repasser a false est le
-- premier reflexe si les crashs reviennent.
--------------------------------------------------------

TAS_CONFIG = {
    hud_state    = true,
    hud_gait     = true,
    hud_position = true,
    hud_rotation = true,
    hud_velocity = true,
    hud_camera   = true,

    -- BISECTION EN COURS (2026-09-08) : les crashs persistent apres
    -- reduction du volume d'appels. On coupe les deux familles de hooks
    -- les moins utiles pour savoir si elles sont en cause.
    --
    --   key_hooks    : 629 keybinds, callbacks sur un autre thread
    --   action_hooks : 10 hooks + AnyKey qui ne se declenchent JAMAIS
    --                  (ActionEvents = 0 mesure sur plusieurs sessions)
    --
    -- Si les crashs cessent : reactiver UNE famille a la fois.
    -- Si les crashs persistent : la cause est dans les lectures du HUD,
    -- desactiver alors hud_state / hud_gait / hud_position /
    -- hud_rotation / hud_velocity une par une.
    action_hooks = false,

    -- key_hooks : DESACTIVE, et ce n'est pas un reglage de confort.
    --
    -- Les callbacks de RegisterKeyBind s'executent sur le thread
    -- d'event loop de UE4SS, pas sur le game thread. Toute execution
    -- Lua y alloue dans le tas partage -- y compris la simple creation
    -- de la closure passee a ExecuteInGameThread, ce qui rend ce
    -- marshalling inoperant : la corruption a lieu avant.
    --
    -- Mesures : zero crash sur toute la periode ou ils etaient coupes
    -- (08/09 12:56 -> 09/09 11:00) ; retour des crashs des leur
    -- reactivation, meme reduits de 629 a 88 keybinds. Signature
    -- constante : getgeneric / luaH_next, adresses faites d'octets
    -- ASCII, donc tas Lua pietine.
    key_hooks    = false
}

-- Duree d'affichage d'une touche, en frames de tick.
-- RegisterKeyBind ne fournit pas d'evenement de relachement : on affiche
-- donc les touches pressees recemment, pas les touches maintenues.
KEY_DISPLAY_FRAMES = 30

-- Marqueur de version : loggue au chargement et affiche par F8.
-- A incrementer a chaque modification, pour verifier que le jeu charge
-- bien le fichier copie et non une version restee en place.
TAS_BUILD = "2026-09-09-16"

TAS = {
    Frame = 0,
    GameTime = 0.0,
    Visible = true,

    HUD = nil,
    Panel = nil,

    TextFrame = nil,
    TextTime = nil,
    TextInput = nil,
    TextEvent = nil,
    TextPosition = nil,
    TextVelocity = nil,
    TextState = nil,
    TextGait = nil,
    TextRotation = nil,
    TextCamera = nil,
    CachedController = nil,
    CachedPawn = nil,
    NextSearchFrame = nil,
    NeedsReset = false,
    TimeIndex = nil,
    TimeDisabled = false,
    KeysDown = {},
    KeyQueue = { n = 0 },
    Actions = {},
    ActionPulse = {},

    InitHandle = nil,
    TickHandle = nil,

    LastEvent = nil,
    LastKey = nil,

    AxisEvents = 0,
    AnyKeyEvents = 0,
    LastAnyKey = nil,

    -- Compteurs de diagnostic : combien de fois les callbacks
    -- ont reellement ete appeles depuis le chargement.
    KeyEvents = 0,
    ActionEvents = 0,
    LastAction = nil,
    SortFailLogged = false
}

--------------------------------------------------------
-- LOGGING
--------------------------------------------------------

local function log(msg)
    print("[ShutterTAS] " .. tostring(msg))
end

--------------------------------------------------------
-- FIND HUD
--------------------------------------------------------

-- Verifie qu'un UObject cache est toujours vivant.
-- Indispensable au chargement d'une partie : les acteurs sont detruits
-- et recrees, et toucher un objet mort fige ou fait planter le jeu.
local function is_alive(object)

    if not object then
        return false
    end

    local ok, valid = pcall(function()
        return object:IsValid()
    end)

    return ok and valid == true
end

-- Declares ici, definis plus bas : plusieurs fonctions d'affichage
-- ont besoin du pawn alors qu'elles precedent sa resolution dans le
-- fichier. Sans ces declarations, l'appel se resout sur un global nil.
local start_init_loop
local get_player_controller
local get_player_pawn
local read_field

--------------------------------------------------------
-- ECRITURE DE TEXTE
--
-- Chaque SetText coute deux passages Lua -> C++ : la construction
-- d'un FText, puis la resolution de la UFunction SetText sur le widget.
-- Les deux ont deja plante UE4SS ici (FText::construct et
-- UFunction::construct dans les dumps).
--
-- La plupart des lignes ne changent pas d'une frame a l'autre :
-- on memorise le dernier texte ecrit et on ne touche au widget que
-- s'il differe. A l'arret, cela ramene 9 ecritures par rafraichissement
-- a une seule (le compteur de frames).
--------------------------------------------------------

local last_text = {}

local function set_text(key, widget, str)

    if last_text[key] == str then
        return
    end

    if not is_alive(widget) then
        last_text[key] = nil
        return
    end

    last_text[key] = str

    widget:SetText(FText(str))
end

-- Repart de zero quand les widgets sont recrees.
local function clear_text_cache()
    last_text = {}
end


local function find_hud()

    local widgets = FindAllOf("HUDWidget_C")

    if not widgets then
        return nil
    end

    if #widgets == 0 then
        return nil
    end

    return widgets[1]
end

--------------------------------------------------------
-- CREATE TEXT BLOCK
--------------------------------------------------------

local function create_text(
    widget_tree,
    parent,
    name,
    x,
    y,
    width,
    height
)

    local text_class = StaticFindObject(
        "/Script/UMG.TextBlock"
    )

    if not text_class then
        log("create_text(" .. name .. ") : classe TextBlock introuvable")
        return nil
    end

    local text = StaticConstructObject(
        text_class,
        widget_tree,
        name
    )

    if not text then
        log("create_text(" .. name .. ") : StaticConstructObject a echoue")
        return nil
    end

    ----------------------------------------------------
    -- SetFontSize() deliberately NOT used.
    -- It is a TrivialObject in this UE4SS build.
    ----------------------------------------------------

    text:SetText(
        FText("")
    )

    local slot = parent:AddChildToCanvas(text)

    if not slot then
        log("create_text(" .. name .. ") : AddChildToCanvas a echoue")
        return nil
    end

    slot:SetPosition({
        X = x,
        Y = y
    })

    slot:SetSize({
        X = width,
        Y = height
    })

    slot:SetZOrder(10)

    return text
end

--------------------------------------------------------
-- CREATE OVERLAY
--------------------------------------------------------

--------------------------------------------------------
-- NETTOYAGE DES OVERLAYS ORPHELINS
--
-- Un hot-reload de UE4SS (touche R par defaut) repart d'un etat Lua
-- vierge : TAS.Panel redevient nil, alors que le panneau precedent est
-- toujours attache au WidgetTree du jeu. Sans ce nettoyage on empile un
-- panneau par rechargement, chacun fige, tous superposes.
--
-- On repere les notres par leur nom d'objet, pose a la construction.
--------------------------------------------------------

local function remove_stale_overlays(root)

    local ok, count = pcall(function()
        return root:GetChildrenCount()
    end)

    if not ok or type(count) ~= "number" then
        return 0
    end

    local removed = 0

    -- A rebours : retirer un enfant decale les suivants.
    for i = count - 1, 0, -1 do

        local ok_child, child = pcall(function()
            return root:GetChildAt(i)
        end)

        if ok_child and is_alive(child) then

            local ok_name, name = pcall(function()
                return child:GetFullName()
            end)

            if ok_name
            and type(name) == "string"
            and name:find("ShutterTAS_Overlay", 1, true) then

                pcall(function()
                    child:RemoveFromParent()
                end)

                removed = removed + 1
            end
        end
    end

    if removed > 0 then
        log("Overlays orphelins retires : " .. tostring(removed))
    end

    return removed
end

local function create_overlay()

    if TAS.Panel then
        return true
    end

    local hud = find_hud()

    if not hud then
        return false
    end

    TAS.HUD = hud

    local widget_tree = hud.WidgetTree

    if not widget_tree then
        TAS.HUD = nil
        return false
    end

    local root = widget_tree.RootWidget

    if not is_alive(root) then
        TAS.HUD = nil
        return false
    end

    ----------------------------------------------------
    -- Un panneau d'une session precedente peut trainer ici.
    ----------------------------------------------------

    remove_stale_overlays(root)

    local canvas_class = StaticFindObject(
        "/Script/UMG.CanvasPanel"
    )

    if not canvas_class then
        TAS.HUD = nil
        return false
    end

    local panel = StaticConstructObject(
        canvas_class,
        widget_tree,
        "ShutterTAS_Overlay"
    )

    if not panel then
        TAS.HUD = nil
        return false
    end

    local root_slot = root:AddChild(panel)

    if not root_slot then
        TAS.HUD = nil
        TAS.Panel = nil
        return false
    end

    root_slot:SetZOrder(9999)

    TAS.Panel = panel

    ----------------------------------------------------
    -- FRAME
    ----------------------------------------------------

    TAS.TextFrame = create_text(
        widget_tree,
        panel,
        "TAS_Frame",
        8,
        8,
        300,
        22
    )

    ----------------------------------------------------
    -- TIME
    ----------------------------------------------------

    TAS.TextTime = create_text(
        widget_tree,
        panel,
        "TAS_Time",
        8,
        42,
        300,
        22
    )

    ----------------------------------------------------
    -- EVENT
    ----------------------------------------------------

    TAS.TextEvent = create_text(
        widget_tree,
        panel,
        "TAS_Event",
        8,
        110,
        400,
        22
    )

    ----------------------------------------------------
    -- ALS STATE
    ----------------------------------------------------

    TAS.TextState = create_text(
        widget_tree,
        panel,
        "TAS_State",
        8,
        144,
        700,
        22
    )

    ----------------------------------------------------
    -- ALS GAIT / LOCOMOTION
    ----------------------------------------------------

    TAS.TextGait = create_text(
        widget_tree,
        panel,
        "TAS_Gait",
        8,
        178,
        700,
        22
    )

    ----------------------------------------------------
    -- POSITION
    ----------------------------------------------------

    TAS.TextPosition = create_text(
        widget_tree,
        panel,
        "TAS_Position",
        8,
        212,
        600,
        22
    )

    ----------------------------------------------------
    -- ROTATION
    ----------------------------------------------------

    TAS.TextRotation = create_text(
        widget_tree,
        panel,
        "TAS_Rotation",
        8,
        246,
        600,
        22
    )

    ----------------------------------------------------
    -- VELOCITY
    ----------------------------------------------------

    TAS.TextVelocity = create_text(
        widget_tree,
        panel,
        "TAS_Velocity",
        8,
        280,
        600,
        22
    )

    ----------------------------------------------------
    -- CAMERA / PHOTO
    ----------------------------------------------------

    TAS.TextCamera = create_text(
        widget_tree,
        panel,
        "TAS_Camera",
        8,
        314,
        1100,
        22
    )

    ----------------------------------------------------
    -- INITIAL TEXT
    ----------------------------------------------------

    if TAS.TextFrame then
        set_text("Frame", TAS.TextFrame, "F 00000000")
    end

    if TAS.TextTime then
        set_text("Time", TAS.TextTime, "T 00:00:00.000")
    end

    if TAS.TextEvent then
        set_text("Event", TAS.TextEvent, "E idle")
    end

    if TAS.TextState then
        set_text("State", TAS.TextState, "S (en attente)")
    end

    if TAS.TextGait then
        set_text("Gait", TAS.TextGait, "G (en attente)")
    end

    if TAS.TextPosition then
        set_text("Position", TAS.TextPosition, "P (en attente)")
    end

    if TAS.TextRotation then
        set_text("Rotation", TAS.TextRotation, "R (en attente)")
    end

    if TAS.TextVelocity then
        set_text("Velocity", TAS.TextVelocity, "V (en attente)")
    end

    if TAS.TextCamera then
        set_text("Camera", TAS.TextCamera, "C (en attente)")
    end


    TAS.Panel:SetVisibility(0)

    return true
end

--------------------------------------------------------
-- VALIDITE DE L'OVERLAY
--
-- Au lancement d'une nouvelle partie, le moteur detruit le HUD et tout
-- son WidgetTree : nos references restent non-nil mais pointent sur de
-- la memoire liberee. Un simple test "if not TAS.Panel" ne voit rien,
-- et le SetText suivant fait dereferencer un objet mort a UE4SS
-- (freeze, ou access violation sur une adresse minuscule).
--
-- On verifie donc la validite reelle, pas seulement la presence.
--------------------------------------------------------

local function overlay_alive()

    ----------------------------------------------------
    -- Verifier les 9 textes ici coutait 11 appels a
    -- IsValid par passage, soit autant de resolutions de
    -- methode sur des UObjects -- le chemin exact de
    -- UFunction::construct dans les dumps.
    --
    -- Les textes sont enfants du panneau : ils meurent
    -- avec lui. Et set_text revalide chaque widget juste
    -- avant d'ecrire, donc rien n'est perdu.
    ----------------------------------------------------

    if not is_alive(TAS.HUD) then return false end
    if not is_alive(TAS.Panel) then return false end

    return true
end


-- Vide les references qui deviennent obsoletes a une transition,
-- sans toucher aux widgets.
local function invalidate_caches()
    TAS.CachedController = nil
    TAS.CachedPawn = nil
    TAS.NextSearchFrame = nil
    clear_text_cache()
end

-- Oublie l'overlay mort et relance la recherche d'un nouveau HUD.
local function reset_overlay()

    ----------------------------------------------------
    -- ClientRestart se declenche aussi quand le HUD survit
    -- (respawn, rechargement de checkpoint). Reconstruire dans
    -- ce cas empile un second panneau par-dessus le premier :
    -- l'ancien reste affiche et fige, le nouveau ecrit dessus.
    ----------------------------------------------------

    if overlay_alive() then
        invalidate_caches()
        return
    end

    log("Overlay invalide, reconstruction")

    ----------------------------------------------------
    -- Si le panneau existe encore mais que des textes sont morts,
    -- le detacher avant d'en creer un autre.
    ----------------------------------------------------

    if is_alive(TAS.Panel) then
        pcall(function()
            TAS.Panel:RemoveFromParent()
        end)
    end

    if TAS.TickHandle then
        CancelDelayedAction(TAS.TickHandle)
        TAS.TickHandle = nil
    end

    TAS.HUD = nil
    TAS.Panel = nil
    TAS.TextFrame = nil
    TAS.TextTime = nil
    TAS.TextInput = nil
    TAS.TextEvent = nil
    TAS.TextState = nil
    TAS.TextGait = nil
    TAS.TextPosition = nil
    TAS.TextRotation = nil
    TAS.TextVelocity = nil

    invalidate_caches()

    if start_init_loop then
        start_init_loop()
    end
end

--------------------------------------------------------
-- UPDATE FRAME TEXT
--------------------------------------------------------

local function update_frame_text()

    if not TAS.Visible then
        return
    end


    set_text(
        "Frame",
        TAS.TextFrame,
        string.format(
                "F %08d",
                TAS.Frame
            )
    )
end

--------------------------------------------------------
-- UPDATE TIME TEXT
--------------------------------------------------------

-- Temps de jeu.
--
-- GetTimeSeconds n'est pas une propriete du pawn : la lire rendait un
-- TrivialObject, ce qui veut dire "absente" (temoin du 09/09). C'est une
-- UFunction statique, qu'on appelle sur l'objet par defaut de la
-- bibliotheque, avec le pawn comme contexte de monde.
--
-- Le nom exact varie selon la bibliotheque : on essaie les formes
-- connues et on loggue celle qui repond.
local TIME_SOURCES = {
    { "/Script/Engine.Default__GameplayStatics",      "GetTimeSeconds"       },
    { "/Script/Engine.Default__KismetSystemLibrary",  "GetGameTimeInSeconds" },
    { "/Script/Engine.Default__GameplayStatics",      "GetRealTimeSeconds"   },
    { "/Script/Engine.Default__GameplayStatics",      "GetAudioTimeSeconds"  }
}

-- La sonde n'a lieu QU'UNE FOIS.
--
-- Appeler une fonction absente leve une erreur Lua, et UE4SS plante en
-- fabriquant la trace (luaL_traceback dans les dumps du 09/09). Sonder
-- quatre sources a chaque rafraichissement, c'etait provoquer des
-- erreurs 7 fois par seconde.
--
-- Une fois la bonne source connue, on n'appelle plus qu'elle. Si aucune
-- ne repond, on abandonne definitivement plutot que de reessayer.
local function game_time(pawn)

    if TAS.TimeDisabled then
        return nil
    end

    ----------------------------------------------------
    -- Source deja connue : appel direct, sans sonde.
    ----------------------------------------------------

    if TAS.TimeIndex then

        local source = TIME_SOURCES[TAS.TimeIndex]

        local ok, value = pcall(function()
            local library = StaticFindObject(source[1])
            if not library then return nil end
            return library[source[2]](library, pawn)
        end)

        if ok and type(value) == "number" then
            return value
        end

        -- la source a cesse de repondre : on ne re-sonde pas
        TAS.TimeDisabled = true
        log("La source de temps a cesse de repondre, ligne T desactivee")
        return nil
    end

    ----------------------------------------------------
    -- Premiere resolution.
    ----------------------------------------------------

    for index, source in ipairs(TIME_SOURCES) do

        local ok, value = pcall(function()
            local library = StaticFindObject(source[1])
            if not library then return nil end
            return library[source[2]](library, pawn)
        end)

        if ok and type(value) == "number" then
            TAS.TimeIndex = index
            log("Temps lu via " .. source[1] .. ":" .. source[2])
            return value
        end
    end

    TAS.TimeDisabled = true
    log("Aucune source de temps ne repond, ligne T desactivee")

    return nil
end


local function update_time_text()

    if not TAS.Visible then
        return
    end

    local pawn = get_player_pawn()

    if not pawn then
        return
    end

    local seconds = game_time(pawn)

    if not seconds then
        return
    end

    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds / 60) % 60
    local sec = math.floor(seconds) % 60
    local ms = math.floor((seconds % 1) * 1000)

    set_text("Time", TAS.TextTime, string.format(
        "T %02d:%02d:%02d.%03d", h, m, sec, ms))
end


--------------------------------------------------------
-- UPDATE EVENT
--------------------------------------------------------

--------------------------------------------------------
-- UPDATE EVENT
--------------------------------------------------------

local function update_event_text()

    if not TAS.Visible then
        return
    end


    ----------------------------------------------------
    -- Vider la file des touches. On echange la table :
    -- les callbacks qui tirent pendant le traitement
    -- ecrivent dans la nouvelle, jamais dans celle qu'on lit.
    ----------------------------------------------------

    local queue = TAS.KeyQueue
    TAS.KeyQueue = { n = 0 }

    for i = 1, queue.n do
        TAS.KeysDown[queue[i]] = TAS.Frame
    end

    ----------------------------------------------------
    -- Purger les touches expirees. On collecte d'abord,
    -- on supprime ensuite : jamais de modification
    -- pendant le parcours.
    ----------------------------------------------------

    local active = {}
    local expired = {}

    for key_name, frame in pairs(TAS.KeysDown) do
        if TAS.Frame - frame > KEY_DISPLAY_FRAMES then
            expired[#expired + 1] = key_name
        else
            active[#active + 1] = { name = key_name, frame = frame }
        end
    end

    for i = 1, #expired do
        TAS.KeysDown[expired[i]] = nil
    end

    ----------------------------------------------------
    -- Un tri qui echoue ne doit pas tuer le tick : l'erreur
    -- LUA_ERRRUN remonte jusqu'a UE4SS et coupe la boucle.
    -- On loggue ce qu'on a recu et on continue non trie.
    ----------------------------------------------------

    local sorted = pcall(function()
        table.sort(active, function(a, b)
            if a.frame == b.frame then
                return a.name < b.name
            end
            return a.frame < b.frame
        end)
    end)

    if not sorted and not TAS.SortFailLogged then

        TAS.SortFailLogged = true

        log("Tri des touches impossible"
            .. " | type(active)=" .. type(active)
            .. " valeur=" .. tostring(active)
            .. " | type(TAS.KeysDown)=" .. type(TAS.KeysDown)
            .. " | type(table)=" .. type(table)
            .. " | type(table.sort)=" .. type(table.sort))

        if type(active) == "table" then
            for i, entry in ipairs(active) do
                log("  active[" .. tostring(i) .. "] type="
                    .. type(entry) .. " valeur=" .. tostring(entry))
            end
        end
    end

    ----------------------------------------------------
    -- Actions maintenues : etat reel, issu des evenements
    -- Pressed/Released du Blueprint. Contrairement aux
    -- keybinds, un Shift tenu reste affiche.
    ----------------------------------------------------

    local held = {}

    for name, down in pairs(TAS.Actions) do
        if down then
            held[#held + 1] = name
        end
    end

    local pulse_expired = {}

    for name, frame in pairs(TAS.ActionPulse) do
        if TAS.Frame - frame > KEY_DISPLAY_FRAMES then
            pulse_expired[#pulse_expired + 1] = name
        else
            held[#held + 1] = name
        end
    end

    for i = 1, #pulse_expired do
        TAS.ActionPulse[pulse_expired[i]] = nil
    end

    pcall(function()
        table.sort(held)
    end)

    ----------------------------------------------------
    -- Rendu : actions a gauche, touches brutes a droite.
    ----------------------------------------------------

    ----------------------------------------------------
    -- Les hooks d'action ne remontent rien (ActionEvents = 0) :
    -- pas de faux "idle" permanent, on n'affiche cette moitie
    -- que si elle a du contenu.
    ----------------------------------------------------

    local left = nil

    if #held > 0 then
        left = table.concat(held, "+")
    end

    local names = {}

    ----------------------------------------------------
    -- Le "+" est deja dans les noms (SHIFT+Z) : le
    -- reutiliser comme separateur rendait la ligne
    -- illisible. On separe les touches par un espace.
    ----------------------------------------------------

    for i = math.max(1, #active - 2), #active do
        names[#names + 1] = active[i].name
    end

    local right = table.concat(names, " ")

    if #active > 3 then
        right = "+" .. tostring(#active - 3) .. " " .. right
    end

    ----------------------------------------------------
    -- Un keybind ne tire qu'a la pression : sans rien de
    -- recent, la ligne retomberait a "idle" une demi-seconde
    -- apres chaque touche. On garde la derniere connue.
    ----------------------------------------------------



    ----------------------------------------------------
    -- Un keybind ne tire qu'a la pression. Sans ce repli,
    -- la ligne se vide une seconde apres chaque touche,
    -- alors que le comportement d'origine gardait la
    -- derniere touche affichee.
    ----------------------------------------------------

    if right == "" and TAS.LastKey then
        right = tostring(TAS.LastKey)
    end

    if not TAS_CONFIG.key_hooks and right == "" then
        right = "(keybinds off)"
    end

    local line

    if left and right ~= "" then
        line = "E " .. left .. "  [" .. right .. "]"
    elseif left then
        line = "E " .. left
    elseif right ~= "" then
        line = "E " .. right
    else
        line = "E -"
    end

    set_text("Event", TAS.TextEvent, line)
end

--------------------------------------------------------
-- PLAYER STATE
--------------------------------------------------------

-- Resolution du controleur et du pawn.
--
-- FindFirstOf fait construire a UE4SS un wrapper Lua d'acteur, et cette
-- construction plante (AActor::construct dans les dumps). On l'appelle
-- donc le moins possible : le controleur est garde tant qu'il est
-- valide, et invalide_caches() le lache a chaque ClientRestart, donc a
-- chaque transition de niveau.
--
-- Une resolution ratee n'est pas retentee avant une seconde.
function get_player_controller()

    if is_alive(TAS.CachedController) then
        return TAS.CachedController
    end

    TAS.CachedController = nil
    TAS.CachedPawn = nil

    if TAS.NextSearchFrame and TAS.Frame < TAS.NextSearchFrame then
        return nil
    end

    TAS.NextSearchFrame = TAS.Frame + CONTROLLER_SEARCH_INTERVAL

    local ok, controller = pcall(function()
        return FindFirstOf("Shutter_PlayerController_C")
    end)

    if not ok or not is_alive(controller) then
        return nil
    end

    TAS.CachedController = controller

    return controller
end

function get_player_pawn()

    if is_alive(TAS.CachedPawn) then
        return TAS.CachedPawn
    end

    TAS.CachedPawn = nil

    local controller = get_player_controller()

    if not controller then
        return nil
    end

    local ok, pawn = pcall(function()
        return controller.Pawn
    end)

    if not ok or not is_alive(pawn) then
        return nil
    end

    TAS.CachedPawn = pawn

    return pawn
end

-- Extrait X/Y/Z d'un FVector renvoye par UE4SS.
-- Renvoie nil si le "vecteur" n'en est pas un (UObject, propriete absente, ...)
local function vector_xyz(v)

    if not v then
        return nil
    end

    local ok, x, y, z = pcall(function()
        return v.X, v.Y, v.Z
    end)

    if not ok then
        return nil
    end

    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end

    return x, y, z
end

--------------------------------------------------------
-- ENUMS ALS
--
-- Keith_BP est un personnage Advanced Locomotion System v4.
-- Les valeurs viennent des UserDefinedEnum du pak :
--   Content/Characters/AdvancedLocomotionV4/Data/Enums/
--
-- OverlayState est specifique a Shutter (Polaroid, Picture, Covered).
--------------------------------------------------------

local ALS_MOVEMENT_STATE = {
    [0] = "None",
    [1] = "Grounded",
    [2] = "InAir",
    [3] = "Ragdoll",
    [4] = "Mantling"
}

local ALS_MOVEMENT_ACTION = {
    [0] = "None",
    [1] = "LowMantle",
    [2] = "HighMantle",
    [3] = "Rolling",
    [4] = "GettingUp"
}

local ALS_STANCE = {
    [0] = "Standing",
    [1] = "Crouching"
}

local ALS_GAIT = {
    [0] = "Walking",
    [1] = "Running",
    [2] = "Sprinting"
}

local ALS_ROTATION_MODE = {
    [0] = "VelocityDir",
    [1] = "LookingDir",
    [2] = "Aiming"
}

local ALS_OVERLAY_STATE = {
    [0] = "Default",
    [1] = "Polaroid",
    [2] = "Picture",
    [3] = "Covered"
}

-- Lit une propriete du pawn sans jamais lever d'erreur.
function read_field(pawn, name)

    local ok, value = pcall(function()
        return pawn[name]
    end)

    if not ok then
        return nil
    end

    return value
end

-- Traduit une valeur d'enum (ByteProperty -> nombre) en nom lisible.
-- Une valeur inconnue s'affiche "?<n>" plutot que de masquer le probleme.
local function enum_name(table_, value)

    if value == nil then
        return "-"
    end

    if type(value) == "number" then
        return table_[value] or ("?" .. tostring(value))
    end

    if type(value) == "string" then
        return value
    end

    return "?" .. type(value)
end

local function read_enum(pawn, name, table_)
    return enum_name(table_, read_field(pawn, name))
end

-- Extrait Pitch/Yaw/Roll d'un FRotator, sur le modele de vector_xyz.
local function rotator_pyr(r)

    if not r then
        return nil
    end

    local ok, pitch, yaw, roll = pcall(function()
        return r.Pitch, r.Yaw, r.Roll
    end)

    if not ok then
        return nil
    end

    if type(pitch) ~= "number"
    or type(yaw) ~= "number"
    or type(roll) ~= "number" then
        return nil
    end

    return pitch, yaw, roll
end

--------------------------------------------------------
-- UPDATE ALS STATE TEXT
--------------------------------------------------------

local function update_state_text()

    if not TAS_CONFIG.hud_state then return end

    if not TAS.Visible then return end

    local pawn = get_player_pawn()

    if not pawn then
        set_text("State", TAS.TextState, "S (pas de pawn)")
        return
    end

    set_text(
        "State",
        TAS.TextState,
        string.format(
        "S %s | %s | %s | %s",
        read_enum(pawn, "MovementState",  ALS_MOVEMENT_STATE),
        read_enum(pawn, "MovementAction", ALS_MOVEMENT_ACTION),
        read_enum(pawn, "Stance",         ALS_STANCE),
        read_enum(pawn, "OverlayState",   ALS_OVERLAY_STATE)
    )
    )
end

--------------------------------------------------------
-- UPDATE GAIT / LOCOMOTION TEXT
--------------------------------------------------------

local function update_gait_text()

    if not TAS_CONFIG.hud_gait then return end

    if not TAS.Visible then return end

    local pawn = get_player_pawn()

    if not pawn then
        set_text("Gait", TAS.TextGait, "G (pas de pawn)")
        return
    end

    local speed = read_field(pawn, "Speed")
    local input = read_field(pawn, "MovementInputAmount")

    set_text(
        "Gait",
        TAS.TextGait,
        string.format(
        "G %s>%s | %s | Spd %s | In %s",
        read_enum(pawn, "Gait",         ALS_GAIT),
        read_enum(pawn, "DesiredGait",  ALS_GAIT),
        read_enum(pawn, "RotationMode", ALS_ROTATION_MODE),
        type(speed) == "number" and string.format("%.1f", speed) or "-",
        type(input) == "number" and string.format("%.2f", input) or "-"
    )
    )
end

local function update_velocity_text()

    if not TAS_CONFIG.hud_velocity then return end
    if not TAS.Visible then return end

    local pawn = get_player_pawn()
    if not pawn then return end

    local ok, velocity = pcall(function()
        return pawn:GetVelocity()
    end)

    if not ok then return end

    local x, y, z = vector_xyz(velocity)

    if not x then return end

    set_text(
        "Velocity",
        TAS.TextVelocity,
        string.format(
        "V X %.2f | Y %.2f | Z %.2f",
        x,
        y,
        z
    )
    )
end


--------------------------------------------------------
-- UPDATE POSITION TEXT
--------------------------------------------------------

-- RelativeLocation n'est pas toujours lisible comme propriete selon le build,
-- on passe donc par les accesseurs Blueprint qui renvoient un vrai FVector.
--
-- Chaque strategie est nommee : la premiere qui rend trois nombres est
-- retenue, et on loggue laquelle (une seule fois) pour savoir ce qui
-- marche reellement sur Shutter.
local function get_player_location(pawn)

    ----------------------------------------------------
    -- Le RootComponent doit etre valide comme le reste :
    -- un simple test nil laisse passer un composant detruit,
    -- et K2_GetComponentLocation plante alors dans
    -- call_ufunction_from_lua.
    ----------------------------------------------------

    local ok_root, root = pcall(function()
        return pawn.RootComponent
    end)

    if not ok_root or not is_alive(root) then
        root = nil
    end

    local strategies = {
        {
            "root:K2_GetComponentLocation()",
            function()
                if not root then return nil end
                return root:K2_GetComponentLocation()
            end
        },
        {
            "pawn:K2_GetActorLocation()",
            function()
                return pawn:K2_GetActorLocation()
            end
        },
        {
            "root.RelativeLocation",
            function()
                if not root then return nil end
                return root.RelativeLocation
            end
        },
        {
            "root.ComponentToWorld.Translation",
            function()
                if not root then return nil end
                local transform = root.ComponentToWorld
                if not transform then return nil end
                return transform.Translation
            end
        }
    }

    for _, strategy in ipairs(strategies) do

        local name = strategy[1]
        local ok, value = pcall(strategy[2])

        if ok then

            local x, y, z = vector_xyz(value)

            if x then

                if TAS.LocationSource ~= name then
                    TAS.LocationSource = name
                    log("Position lue via " .. name)
                end

                return x, y, z
            end
        end
    end

    if not TAS.LocationFailLogged then

        TAS.LocationFailLogged = true

        log("Aucune strategie de lecture de position n'a fonctionne")

        for _, strategy in ipairs(strategies) do

            local name = strategy[1]
            local ok, value = pcall(strategy[2])

            log("  " .. name
                .. " -> ok=" .. tostring(ok)
                .. " value=" .. tostring(value)
                .. " type=" .. type(value))

            if ok and value then
                local ok_x, x = pcall(function() return value.X end)
                log("      .X -> ok=" .. tostring(ok_x)
                    .. " value=" .. tostring(x)
                    .. " type=" .. type(x))
            end
        end
    end

    return nil
end

local function update_position_text()

    if not TAS_CONFIG.hud_position then return end

    if not TAS.Visible then
        return
    end


    local pawn = get_player_pawn()

    if not pawn then
        set_text("Position", TAS.TextPosition, "P (pas de pawn)")
        return
    end

    local x, y, z = get_player_location(pawn)

    if not x then
        set_text("Position", TAS.TextPosition, "P (lecture impossible)")
        return
    end

    set_text(
        "Position",
        TAS.TextPosition,
        string.format(
                "P X %.2f | Y %.2f | Z %.2f",
                x,
                y,
                z
            )
    )
end
-- Types d'objets photographiables, enum ShutterMeshTypes du pak.
local SHUTTER_MESH_TYPES = {
    [0] = "SimulatedMesh",
    [1] = "Door",
    [2] = "StaticMesh",
    [3] = "Anomaly"
}

-- Membres de la struct SavedPicture. Mesure du 09/09 : seul le nom
-- MANGLE repond, le nom propre rend nil.
local SAVED_PICTURE = {
    -- ClassProperty de type Actor : la classe de l'objet capture.
    -- C'est bien le jeu qui sait ce qu'on porte, l'information est ici.
    ObjectClass = "ObjectClass_3_2E318B9E4DCA7623E78998836176AB2B",
    SlotUsed = "SlotUsed_16_DE00E4E54FAA1A4F35336E86899D8FDA",
    MeshType = "MeshType_6_B973D37A4C5EDBA5804797B1DEE608C3",
    Distance = "OriginalDistance_9_C9D297ED4EB05D189145C3AB43A322D2",
    Scale    = "Original_Scale_19_95CE6A50443ECA8CEF58D9917DD5835D",
    Rotation = "OriginalRotation_12_C4EE90F54AAA367186D8559D3CD82973",
    MinSize  = "MinSize_29_87A1DD094B66CCF61AC01FBF6E9300F9",
    MaxSize  = "MaxSize_31_E330C3924C312B4E4D491DAE5F5236EF",
    Code     = "NumberCode_34_5CFFC18C490F005286B16D8FF2F6F829"
}

-- Rend une valeur lisible. Le deballage des TrivialObject a ete retire :
-- le temoin du 09/09 a montre qu'ils signalent une propriete ABSENTE,
-- il n'y a rien dedans a deballer.
local function describe(value)

    if value == nil then
        return "-"
    end

    local t = type(value)

    if t == "boolean" then
        return value and "oui" or "non"
    end

    if t == "number" then
        if value == math.floor(value) then
            return tostring(math.floor(value))
        end
        return string.format("%.2f", value)
    end

    if t == "string" then
        return value
    end

    return t
end

local function picture_field(struct, key)

    if struct == nil then
        return nil
    end

    return read_field(struct, SAVED_PICTURE[key])
end

--------------------------------------------------------
-- UPDATE CAMERA / PHOTO TEXT
--
-- Ce qui N'EST PAS lisible, et pourquoi :
--   - le nom de l'objet capture : PictureMesh est le plan de la photo
--     tenue en main, toujours le meme mesh ; l'objet n'existe que dans
--     PictureMaterial, un materiau dynamique.
--   - l'echelle courante : BlueItemScale et DesiredScale sont des
--     locales de fonction, pas des membres (temoin du 09/09).
--
-- Ce qui EST lisible et varie d'un objet a l'autre : la categorie et
-- les bornes de redimensionnement, qui forment une signature utile --
-- 0.10-0.50 pour l'un, 0.10-0.60 pour un autre.
--------------------------------------------------------

-- Nom court de la classe capturee.
-- "BlueprintGeneratedClass /Game/.../Chaise.Chaise_C" -> "Chaise_C"
local function stored_class_name(inventory)

    local class = picture_field(inventory, "ObjectClass")

    if not is_alive(class) then
        return nil
    end

    local ok, full = pcall(function()
        return class:GetFullName()
    end)

    if not ok or type(full) ~= "string" then
        return nil
    end

    return full:match("([^%.]+)$") or full
end

-- Echelle a la capture. Presque toujours uniforme : on n'affiche les
-- trois axes que s'ils different.
local function scale_text(inventory)

    local x, y, z = vector_xyz(picture_field(inventory, "Scale"))

    if not x then
        return "-"
    end

    if x == y and y == z then
        return string.format("%.2f", x)
    end

    return string.format("%.2f/%.2f/%.2f", x, y, z)
end

-- Rotation a la capture, en Pitch/Yaw/Roll arrondis.
local function rotation_text(inventory)

    local pitch, yaw, roll = rotator_pyr(picture_field(inventory, "Rotation"))

    if not pitch then
        return "-"
    end

    return string.format("%d/%d/%d",
        math.floor(pitch + 0.5),
        math.floor(yaw + 0.5),
        math.floor(roll + 0.5))
end

local function update_camera_text()

    if not TAS_CONFIG.hud_camera then return end
    if not TAS.Visible then return end

    local pawn = get_player_pawn()

    if not pawn then
        return
    end

    local inventory = read_field(pawn, "PictureInventory")

    if picture_field(inventory, "SlotUsed") ~= true then
        set_text("Camera", TAS.TextCamera, "C vide")
        return
    end

    set_text("Camera", TAS.TextCamera, string.format(
        "C %s (%s) | Ech %s | Rot %s | Bornes %s-%s | Dist %s | Code %s",
        stored_class_name(inventory) or "?",
        enum_name(SHUTTER_MESH_TYPES, picture_field(inventory, "MeshType")),
        scale_text(inventory),
        rotation_text(inventory),
        describe(picture_field(inventory, "MinSize")),
        describe(picture_field(inventory, "MaxSize")),
        describe(picture_field(inventory, "Distance")),
        describe(picture_field(inventory, "Code"))
    ))
end

--------------------------------------------------------
-- UPDATE ROTATION TEXT
--
-- La rotation de l'acteur ET celle du controleur sont necessaires :
-- restaurer l'une sans l'autre laisse la camera desynchronisee.
--------------------------------------------------------

local function update_rotation_text()

    if not TAS_CONFIG.hud_rotation then return end

    if not TAS.Visible then return end

    local pawn = get_player_pawn()

    if not pawn then
        set_text("Rotation", TAS.TextRotation, "R (pas de pawn)")
        return
    end

    local ok, rotation = pcall(function()
        return pawn:K2_GetActorRotation()
    end)

    local yaw_text = "-"

    if ok then
        local pitch, yaw = rotator_pyr(rotation)
        if pitch then
            yaw_text = string.format("%.2f", yaw)
        end
    end

    local control_text = "-"

    local controller = get_player_controller()

    local ok_c, control = pcall(function()
        if not controller then return nil end
        return controller:GetControlRotation()
    end)

    if ok_c then
        local pitch, yaw = rotator_pyr(control)
        if pitch then
            control_text = string.format("%.2f/%.2f", pitch, yaw)
        end
    end

    set_text(
        "Rotation",
        TAS.TextRotation,
        string.format(
        "R Yaw %s | Cam P/Y %s",
        yaw_text,
        control_text
    )
    )
end

--------------------------------------------------------
-- UPDATE HUD
--------------------------------------------------------

local function update_hud()

    if not TAS.Panel then
        return
    end

    update_frame_text()
    update_time_text()
    update_event_text()
    update_state_text()
    update_gait_text()
    update_position_text()
    update_rotation_text()
    update_velocity_text()
    update_camera_text()
end


--------------------------------------------------------
-- KEY INPUT HOOKS
--------------------------------------------------------

local KeyHooksInstalled = false

-- Un callback de touche doit rester purement Lua.
--
-- Ecrire dans l'UMG ici coutait un FText + un SetText par pression :
-- en spammant, ce sont exactement les appels qui font planter UE4SS
-- (FText::construct, UFunction::construct dans les dumps). Et comme
-- chaque pression ecrasait la precedente, une seule touche s'affichait.
--
-- On se contente donc d'horodater la touche ; le tick fait le rendu.
local function make_key_callback(key_name)

    return function()

        TAS.LastKey = key_name

        ------------------------------------------------
        -- Ecrire directement dans la table que le tick
        -- parcourt avec pairs() peut declencher un rehash
        -- en pleine iteration : comportement indefini,
        -- et crash dans luaH_next (constate dans le dump).
        --
        -- On empile donc dans une file que le tick echange.
        ------------------------------------------------

        ------------------------------------------------
        -- Les callbacks de keybind s'executent sur le
        -- thread d'event loop de UE4SS, pas sur le game
        -- thread ou tourne le tick. Ecrire directement
        -- dans les tables partagees, c'est deux threads
        -- sur le meme lua_State : corruption de table,
        -- puis crash dans luaH_next ou getgeneric.
        --
        -- ExecuteInGameThread reporte l'ecriture sur le
        -- bon thread.
        ------------------------------------------------

        pcall(function()
            ExecuteInGameThread(function()
                TAS.KeyEvents = TAS.KeyEvents + 1
                local queue = TAS.KeyQueue
                queue.n = queue.n + 1
                queue[queue.n] = key_name
            end)
        end)
    end

end

local function install_key_hooks()

    if KeyHooksInstalled then
        return
    end

    if not TAS_CONFIG.key_hooks then
        log("Key input hooks desactives (TAS_CONFIG.key_hooks)")
        KeyHooksInstalled = true
        return
    end

    ----------------------------------------------------
    -- Key is the UE4SS table containing all supported
    -- keyboard / mouse keys.
    --
    -- We register each key individually because
    -- RegisterKeyBind does not have a wildcard key.
    ----------------------------------------------------

    ----------------------------------------------------
    -- Shift, Ctrl et Alt n'existent pas dans la table Key
    -- de UE4SS : ce sont uniquement des ModifierKey. La
    -- seule facon de les voir est d'enregistrer chaque
    -- touche une fois par combinaison de modificateurs.
    --
    -- Un bind sans modificateur ne tire pas si un
    -- modificateur est enfonce : c'est pour ca que Shift+Z
    -- n'affichait rien du tout jusqu'ici.
    ----------------------------------------------------

    ----------------------------------------------------
    -- Enregistrer les ~157 touches x 4 modificateurs faisait
    -- 629 keybinds, et la bisection du 08/09 les designe comme
    -- principal suspect des crashs : zero crash pendant toute
    -- la periode ou ils etaient coupes.
    --
    -- On se limite donc aux touches reellement utiles en jeu.
    -- Vider cette liste rebascule sur toutes les touches.
    ----------------------------------------------------

    local GAMEPLAY_KEYS = {
        Z = true, Q = true, S = true, D = true,
        W = true, A = true,
        E = true, R = true, F = true, C = true, X = true,
        SPACE = true, TAB = true, ESCAPE = true, RETURN = true,
        LEFT_MOUSE_BUTTON = true,
        RIGHT_MOUSE_BUTTON = true,
        MIDDLE_MOUSE_BUTTON = true,
        ONE = true, TWO = true, THREE = true, FOUR = true
    }

    local MODIFIER_SETS = {
        { nil,                      ""       },
        { { ModifierKey.SHIFT },    "SHIFT+" },
        { { ModifierKey.CONTROL },  "CTRL+"  },
        { { ModifierKey.ALT },      "ALT+"   }
    }

    local registered = 0

    for key_name, key_code in pairs(Key) do

        ------------------------------------------------
        -- Ignore the reserved enum value.
        ------------------------------------------------

        if key_code ~= 0 then

            ------------------------------------------------
            -- F7 and F8 already have dedicated bindings.
            ------------------------------------------------

            if GAMEPLAY_KEYS[key_name]
            and key_code ~= Key.F7
            and key_code ~= Key.F8
            and key_code ~= Key.F9
            and key_code ~= Key.F1 then

                local ok = pcall(
                    function()

                        for _, variant in ipairs(MODIFIER_SETS) do

                            local mods, prefix = variant[1], variant[2]

                            if mods then

                                if not IsKeyBindRegistered(key_code, mods) then
                                    RegisterKeyBind(
                                        key_code,
                                        mods,
                                        make_key_callback(prefix .. key_name)
                                    )
                                    registered = registered + 1
                                end

                            else

                                if not IsKeyBindRegistered(key_code) then
                                    RegisterKeyBind(
                                        key_code,
                                        make_key_callback(key_name)
                                    )
                                    registered = registered + 1
                                end
                            end
                        end

                    end
                )

                if not ok then

                    log(
                        "Failed to register key: " ..
                        tostring(key_name)
                    )

                end

            end

        end

    end

    KeyHooksInstalled = true

    log(
        "Key input hooks installed: " ..
        tostring(registered)
    )

end

--------------------------------------------------------
-- ENGINE FRAME
--------------------------------------------------------

local function tas_tick()

    ----------------------------------------------------
    -- Stop touching UMG if the HUD is gone.
    ----------------------------------------------------

    ----------------------------------------------------
    -- Une transition de niveau vient d'avoir lieu : tout
    -- ce qu'on garde en cache pointe sur des objets morts.
    ----------------------------------------------------

    if TAS.NeedsReset then
        TAS.NeedsReset = false
        reset_overlay()
        return
    end


    ----------------------------------------------------
    -- THIS IS THE TAS FRAME.
    --
    -- Increment exactly once for every delayed-action
    -- frame callback.
    ----------------------------------------------------

    TAS.Frame = TAS.Frame + 1

    ----------------------------------------------------
    -- Le compteur change a chaque frame, donc l'afficher a
    -- chaque frame cree un FText par frame -- et
    -- FText::construct est ce qui plante le plus souvent
    -- dans les dumps. C'etait la seule ligne qui echappait
    -- au throttle.
    --
    -- TAS.Frame reste incremente a chaque frame : seul
    -- l'affichage est espace.
    ----------------------------------------------------

    if TAS.Frame % HUD_REFRESH_INTERVAL ~= 0 then
        return
    end

    ----------------------------------------------------
    -- On ne valide qu'au moment d'ecrire, pas a chaque frame.
    ----------------------------------------------------

    if not overlay_alive() then
        reset_overlay()
        return
    end

    update_frame_text()

    -- Le temps n'a pas besoin de 7 Hz : un rafraichissement sur 4 suffit,
    -- et chaque lecture est un aller-retour Lua -> C++.
    if TAS.Frame % (HUD_REFRESH_INTERVAL * 4) == 0 then
        update_time_text()
    end

    update_event_text()
    update_state_text()
    update_gait_text()
    update_position_text()
    update_rotation_text()
    update_velocity_text()
    update_camera_text()

end

--------------------------------------------------------
-- STOP FRAME LOOP
--------------------------------------------------------

local function stop_tick_loop()

    if TAS.TickHandle then

        CancelDelayedAction(
            TAS.TickHandle
        )

        TAS.TickHandle = nil
    end
end

--------------------------------------------------------
-- START FRAME LOOP
--------------------------------------------------------

local function start_tick_loop()

    if TAS.TickHandle then
        return
    end

    TAS.TickHandle = LoopInGameThreadAfterFrames(
        1,
        function()

            ------------------------------------------------
            -- tas_tick valide l'overlay et le reconstruit
            -- lui-meme s'il a ete detruit.
            ------------------------------------------------

            tas_tick()

        end
    )
end

--------------------------------------------------------
-- HOOKS SUR LES ACTIONS DU BLUEPRINT
--
-- RegisterKeyBind ne donne pas d'evenement de relachement, et une
-- touche modificatrice comme Shift ne declenche meme pas les binds
-- simples. Les evenements du Blueprint, eux, ont une fonction par
-- broche : quand une action expose deux index, c'est Pressed et
-- Released, donc un vrai etat maintenu.
--
-- Noms releves par le scan F9 sur Keith_BP_C.
--------------------------------------------------------

local KEITH = "/Game/Characters/Keith/Keith_BP.Keith_BP_C:"

-- Les hooks poses sur Keith ne tirent jamais (ActionEvents = 0), alors
-- que ceux du PlayerController tournent en continu (AxisEvents = 53660).
-- On vise donc la classe qui fonctionne.
local PC = "/Game/Blueprints/GameMode/Shutter_PlayerController.Shutter_PlayerController_C:"

-- { nom affiche, fonction, valeur posee }
local ACTION_HOOKS = {
    { "Run",   "InpActEvt_RunAction_K2Node_InputActionEvent_0",       true  },
    { "Run",   "InpActEvt_RunAction_K2Node_InputActionEvent_1",       false },
    { "Jump",  "InpActEvt_JumpAction_K2Node_InputActionEvent_8",      true  },
    { "Jump",  "InpActEvt_JumpAction_K2Node_InputActionEvent_9",      false },
    { "Scale", "InpActEvt_ObjectScaleMode_K2Node_InputActionEvent_2", true  },
    { "Scale", "InpActEvt_ObjectScaleMode_K2Node_InputActionEvent_3", false }
}

-- Une seule fonction exposee : on ne voit que la pression.
local PULSE_HOOKS = {
    { "Aim",      "InpActEvt_Aim_K2Node_InputActionEvent_4"      },
    { "Shoot",    "InpActEvt_Shoot_K2Node_InputActionEvent_5"    },
    { "Interact", "InpActEvt_Interact_K2Node_InputActionEvent_7" },
    { "Cancel",   "InpActEvt_Cancel_K2Node_InputActionEvent_6"   }
}

local ActionHooksInstalled = false

local function install_action_hooks()

    if ActionHooksInstalled then
        return
    end

    if not TAS_CONFIG.action_hooks then
        return
    end

    local installed = 0

    for _, entry in ipairs(ACTION_HOOKS) do

        local name, fn, value = entry[1], entry[2], entry[3]

        local ok = pcall(function()
            RegisterHook(
                KEITH .. fn,
                function() end,
                function()
                    -- callback purement Lua : aucun acces UObject
                    TAS.ActionEvents = TAS.ActionEvents + 1
                    TAS.LastAction = name .. "=" .. tostring(value)
                    TAS.Actions[name] = value
                end
            )
        end)

        if ok then
            installed = installed + 1
        else
            log("Hook action echoue : " .. fn)
        end
    end

    for _, entry in ipairs(PULSE_HOOKS) do

        local name, fn = entry[1], entry[2]

        local ok = pcall(function()
            RegisterHook(
                KEITH .. fn,
                function() end,
                function()
                    TAS.ActionEvents = TAS.ActionEvents + 1
                    TAS.LastAction = name
                    TAS.ActionPulse[name] = TAS.Frame
                end
            )
        end)

        if ok then
            installed = installed + 1
        else
            log("Hook action echoue : " .. fn)
        end
    end

    ----------------------------------------------------
    -- AnyKey sur le PlayerController : l'evenement d'input
    -- du jeu lui-meme, qui voit toutes les touches, Shift
    -- compris. Le compilateur Blueprint genere une fonction
    -- par broche (Pressed / Released) avec un index qu'on
    -- ne peut pas deviner : on sonde 0 a 9 et on garde
    -- celles qui existent.
    ----------------------------------------------------

    local anykey = 0

    for i = 0, 9 do

        local fn = "InpActEvt_AnyKey_K2Node_InputKeyEvent_" .. tostring(i)
        local index = i

        local ok = pcall(function()
            RegisterHook(
                PC .. fn,
                function() end,
                function()
                    TAS.AnyKeyEvents = TAS.AnyKeyEvents + 1
                    TAS.LastAnyKey = index
                end
            )
        end)

        if ok then
            anykey = anykey + 1
            log("  AnyKey hook pose sur l'index " .. tostring(i))
        end
    end

    log("AnyKey hooks : " .. tostring(anykey))

    ActionHooksInstalled = true

    log("Action hooks installes : " .. tostring(installed))
end

--------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------

local function try_initialize()

    if not create_overlay() then
        return
    end

    ----------------------------------------------------
    -- Cancel initialization loop.
    ----------------------------------------------------

    if TAS.InitHandle then

        CancelDelayedAction(
            TAS.InitHandle
        )

        TAS.InitHandle = nil
    end

    ----------------------------------------------------
    -- Install live input hooks.
    ----------------------------------------------------

    install_key_hooks()
    install_action_hooks()

    ----------------------------------------------------
    -- Initial display.
    ----------------------------------------------------

    update_hud()

    ----------------------------------------------------
    -- Start per-frame TAS counter.
    ----------------------------------------------------

    start_tick_loop()

    log("HUD initialized successfully")
end

--------------------------------------------------------
-- BOUCLE D'INITIALISATION
--
-- Relancable : appelee au chargement du mod, puis a chaque fois que
-- l'overlay est detruit par un changement de niveau.
--------------------------------------------------------

function start_init_loop()

    if TAS.InitHandle then
        return
    end

    TAS.InitHandle = LoopInGameThreadWithDelay(
        500,
        function()
            try_initialize()
        end
    )
end

--------------------------------------------------------
-- TRANSITION DE NIVEAU
--
-- ClientRestart est appele par le moteur quand il (re)met en place le
-- PlayerController : nouvelle partie, changement de niveau, respawn.
-- C'est exactement le moment ou HUD, widgets et pawn sont detruits,
-- et ou nos references deviennent des pointeurs morts.
--
-- On ne fait rien de lourd dans le hook lui-meme : il pose un drapeau,
-- et le tick reconstruit dans un contexte sur.
--------------------------------------------------------

local LevelHookInstalled = false

local function install_level_hook()

    if LevelHookInstalled then
        return
    end

    local ok = pcall(
        function()
            RegisterHook(
                "/Script/Engine.PlayerController:ClientRestart",
                function() end,
                function()
                    TAS.NeedsReset = true
                end
            )
        end
    )

    if ok then
        LevelHookInstalled = true
        log("Level transition hook installed")
    else
        log("Level transition hook failed")
    end
end

--------------------------------------------------------
-- F7
--------------------------------------------------------

RegisterKeyBind(
    Key.F7,
    function()

        TAS.Visible = not TAS.Visible

        if TAS.Panel then

            if TAS.Visible then

                TAS.Panel:SetVisibility(0)

                update_frame_text()
                update_input_text()
                update_event_text()

            else

                TAS.Panel:SetVisibility(1)

            end
        end
    end
)

local function debug_vector_properties()
    log("----------------------------------------")
    log("VECTOR PROPERTY DEBUG")

    local controller = FindFirstOf("Shutter_PlayerController_C")
    if not controller then
        log("No controller")
        return
    end

    local pawn = controller.Pawn
    if not pawn then
        log("No pawn")
        return
    end

    local root = pawn.RootComponent
    if not root then
        log("No RootComponent")
        return
    end

    local location = root.RelativeLocation
    local velocity = root.ComponentVelocity

    log("RelativeLocation = " .. tostring(location))
    log("  X = " .. tostring(location.X))
    log("  Y = " .. tostring(location.Y))
    log("  Z = " .. tostring(location.Z))

    log("ComponentVelocity = " .. tostring(velocity))
    log("  X = " .. tostring(velocity.X))
    log("  Y = " .. tostring(velocity.Y))
    log("  Z = " .. tostring(velocity.Z))

    log("----------------------------------------")
end
local function debug_movement_properties()
    log("----------------------------------------")
    log("MOVEMENT DEBUG")

    local controller = FindFirstOf("Shutter_PlayerController_C")
    if not controller then
        log("No controller")
        return
    end

    local pawn = controller.Pawn
    if not pawn then
        log("No pawn")
        return
    end

    log("CharacterMovement = " .. tostring(pawn.CharacterMovement))

    if pawn.CharacterMovement then
        local movement = pawn.CharacterMovement
        local velocity = movement.Velocity

        log("Movement Velocity = " .. tostring(velocity))

        if velocity then
            log("  X = " .. tostring(velocity.X))
            log("  Y = " .. tostring(velocity.Y))
            log("  Z = " .. tostring(velocity.Z))
        end
    end

    log("----------------------------------------")
end
--------------------------------------------------------
-- F10 : SONDE DES PROPRIETES DU PAWN
--
-- Un nom lu dans le pak peut etre une variable locale de fonction
-- plutot qu'un membre accessible (cf. ActualGait, qui renvoie un
-- userdata). Cette sonde dit lesquels repondent vraiment, et avec
-- quel type -- avant de batir un affichage dessus.
--------------------------------------------------------

local PAWN_PROBE = {
    "PictureInventory", "PictureTaken", "PictureLoaded",
    "PictureMesh", "PictureMaterial", "PictureDissolve",
    "CameraAvailable", "CameraSensitivity",
    "ClosestObject", "ObjectInRange", "ObjectHit",
    "LastObjectHitDistance", "ObjectType",
    "ObjectScaleMode", "ObjectScaleRate",
    "BlueItemScale", "DesiredScale",
    "HasRoom", "CanSprint", "CamTargetLocation"
}

-- F10 est deja pris par ConsoleEnabler (ConsoleKey[3]).
RegisterKeyBind(
    Key.F1,
    function()

        log("----------------------------------------")
        log("SONDE DES PROPRIETES DU PAWN")

        local pawn = get_player_pawn()

        if not pawn then
            log("Pas de pawn")
            return
        end

        local found = 0

        for _, name in ipairs(PAWN_PROBE) do

            local value = read_field(pawn, name)

            if value == nil then
                log(string.format("  %-24s absent", name))
            else
                found = found + 1

                local extra = ""

                if type(value) == "userdata" then
                    for _, method in ipairs(UNWRAP_METHODS) do
                        local ok, result = pcall(function()
                            return value[method](value)
                        end)
                        if ok and result ~= nil then
                            extra = extra .. "  :" .. method .. "()="
                                .. type(result) .. "/" .. tostring(result)
                        end
                    end
                    if extra == "" then
                        extra = "  (aucun accesseur ne repond)"
                    end
                end

                log(string.format("  %-24s %-10s %s%s",
                    name, type(value), tostring(value), extra))
            end
        end

        log("Proprietes lisibles : " .. tostring(found)
            .. " / " .. tostring(#PAWN_PROBE))

        ------------------------------------------------
        -- Temoin : un nom volontairement inexistant.
        -- S'il rend lui aussi un TrivialObject, alors
        -- TrivialObject veut dire "propriete absente",
        -- et les champs concernes sont des locales de
        -- fonction, pas des membres.
        ------------------------------------------------

        local temoin = read_field(pawn, "ZZ_PropieteQuiNExistePas")

        log("  TEMOIN inexistant       " .. type(temoin)
            .. "  " .. tostring(temoin))

        ------------------------------------------------
        -- Contenu de la struct SavedPicture.
        ------------------------------------------------

        log("  --- PictureInventory (SavedPicture) ---")

        local inventory = read_field(pawn, "PictureInventory")

        for key, mangled in pairs(SAVED_PICTURE) do

            local clair = read_field(inventory, key)
            local brut = read_field(inventory, mangled)

            log(string.format("    %-10s propre=%s/%s  mangle=%s/%s",
                key,
                type(clair), tostring(clair),
                type(brut), tostring(brut)))
        end
        log("----------------------------------------")
    end
)

--------------------------------------------------------
-- F9 : DECOUVERTE DES FONCTIONS D'INPUT
--
-- RegisterKeyBind ne donne pas d'evenement de relachement, donc pas
-- d'etat maintenu. Les evenements d'input du Blueprint, eux, ont des
-- broches Pressed ET Released, et le compilateur genere une fonction
-- par broche avec un index qu'on ne peut pas deviner.
--
-- Ce scan liste les noms exacts pour pouvoir les hooker ensuite.
--------------------------------------------------------

RegisterKeyBind(
    Key.F9,
    function()

        log("----------------------------------------")
        log("SCAN DES FONCTIONS D'INPUT")

        local found = 0

        local ok = pcall(function()

            ForEachUObject(function(object)

                local ok_name, name = pcall(function()
                    return object:GetFullName()
                end)

                if ok_name and type(name) == "string" then

                    if name:find("InpActEvt", 1, true)
                    or name:find("InpAxisEvt", 1, true)
                    or name:find("InputKeyEvent", 1, true) then

                        log("  " .. name)
                        found = found + 1
                    end
                end
            end)
        end)

        if not ok then
            log("ForEachUObject indisponible")
        end

        log("Fonctions d'input trouvees : " .. tostring(found))
        log("----------------------------------------")
    end
)

--------------------------------------------------------
-- F8 DEBUG
--------------------------------------------------------

RegisterKeyBind(
    Key.F8,
    function()

        log("----------------------------------------")
        log("TAS DEBUG")

        log(
            "BUILD      = " ..
            tostring(TAS_BUILD)
        )

        log(
            "Frame      = " ..
            tostring(TAS.Frame)
        )

        log(
            "GameTime   = " ..
            tostring(TAS.GameTime)
        )

        log(
            "Visible    = " ..
            tostring(TAS.Visible)
        )

        log(
            "LastKey    = " ..
            tostring(TAS.LastKey)
        )

        log(
            "KeyHooks   = " ..
            tostring(KeyHooksInstalled)
        )

        log(
            "HUD        = " ..
            tostring(TAS.HUD)
        )

        log(
            "HUD        = " ..
            tostring(TAS.HUD)
        )

        log(
            "Panel      = " ..
            tostring(TAS.Panel)
        )

        log(
            "TextFrame  = " ..
            tostring(TAS.TextFrame)
        )

        log(
            "TextTime   = " ..
            tostring(TAS.TextTime)
        )

        log(
            "TextInput  = " ..
            tostring(TAS.TextInput)
        )

        log(
            "TextEvent  = " ..
            tostring(TAS.TextEvent)
        )

        log(
            "TextPosition = " ..
            tostring(TAS.TextPosition)
        )

        log(
            "TextVelocity = " ..
            tostring(TAS.TextVelocity)
        )

        log(
            "TextState    = " ..
            tostring(TAS.TextState)
        )

        log(
            "TextGait     = " ..
            tostring(TAS.TextGait)
        )

        log(
            "TextRotation = " ..
            tostring(TAS.TextRotation)
        )

        log(
            "KeyEvents    = " ..
            tostring(TAS.KeyEvents)
        )

        log(
            "AxisEvents   = " ..
            tostring(TAS.AxisEvents)
        )

        log(
            "AnyKeyEvents = " ..
            tostring(TAS.AnyKeyEvents)
        )

        log(
            "LastAnyKey   = " ..
            tostring(TAS.LastAnyKey)
        )

        log(
            "ActionEvents = " ..
            tostring(TAS.ActionEvents)
        )

        log(
            "LastAction   = " ..
            tostring(TAS.LastAction)
        )

        log(
            "LastKey      = " ..
            tostring(TAS.LastKey)
        )

        local down = 0
        for _ in pairs(TAS.KeysDown) do
            down = down + 1
        end

        log(
            "KeysDown     = " ..
            tostring(down)
        )

        for name, value in pairs(TAS.Actions) do
            log("  Action " .. name .. " = " .. tostring(value))
        end

        log(
            "LocationSource = " ..
            tostring(TAS.LocationSource)
        )

        log(
            "InitHandle = " ..
            tostring(TAS.InitHandle)
        )

        log(
            "TickHandle = " ..
            tostring(TAS.TickHandle)
        )

        log("----------------------------------------")
        log("----------------------------------------")
        log("PLAYER STATE DEBUG")

        local controller = FindFirstOf(
            "Shutter_PlayerController_C"
        )

        log("Controller = " .. tostring(controller))

        if controller then

            local pawn = controller.Pawn

            log("Pawn = " .. tostring(pawn))

            if pawn then

                log("Pawn FullName = " .. tostring(pawn:GetFullName()))

                local root = pawn.RootComponent

                log("RootComponent = " .. tostring(root))

                if root then
                    log("Root FullName = " .. tostring(root:GetFullName()))
                end

            end

        end

        debug_vector_properties()
        debug_movement_properties()

        
    end
)

--------------------------------------------------------
-- STARTUP
--------------------------------------------------------

log("ShutterTAS loaded")
log("BUILD = " .. TAS_BUILD)
log("Compact TAS HUD")
log(
    "EngineTickAvailable = " ..
    tostring(EngineTickAvailable)
)
log("F7 = Toggle HUD")
log("F8 = Debug")
log("F9 = Scan des fonctions d'input")
log("F1 = Sonde des proprietes du pawn")

--------------------------------------------------------
-- WAIT FOR HUD
--------------------------------------------------------

install_level_hook()

start_init_loop()


