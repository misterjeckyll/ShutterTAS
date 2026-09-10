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
    -- Hooks d'axe du PlayerController : game thread, sains (119 000
    -- appels mesures sans incident). Canal principal de l'enregistreur.
    axis_hooks   = true,

    -- Diagnostic : les hooks d'action de Keith n'ont jamais tire. Actifs,
    -- ils ne coutent rien ; s'ils tirent un jour, les logs le diront.
    action_hooks = true,

    -- Logs de diagnostic automatiques pendant REC, PLAY et la sonde V.
    -- Volontairement bavards ; false pour les couper.
    debug_log    = true,

    -- Diagnostic REC / PLAY (10/09) : trace de toutes les fonctions de
    -- Keith, instantanes de ses variables, appels aux timelines et
    -- detecteur de drift. Tres bavard, plusieurs centaines de hooks :
    -- false pour tout couper si les crashs reviennent.
    diag_trace   = true,

    -- Instantane des variables de Keith toutes les N frames, en plus des
    -- evenements (saut, timeline, MovementState). Plus petit = divergence
    -- situee plus finement, mais plus d'appels Lua <-> C++.
    diag_snap_interval = 10,

    -- Pas de temps fixe (10/09, build -15). Sans lui, chaque frame dure le
    -- temps reel ecoule : un a-coup de 9 % sur une seule frame a donne
    -- +1,64 de vitesse en PLAY, puis tout diverge. bUseFixedFrameRate du
    -- moteur impose 1/fixed_fps a chaque frame. nil pour ne pas y toucher.
    --
    -- Historique : au build -15, le jeu est parti en accelere. En cause,
    -- d'apres le test de l'utilisateur, l'argument -UseFixedTimeStep, retire
    -- depuis ; bUseFixedFrameRate etait actif en meme temps, jamais teste
    -- seul. Garde-fou (time_report) : si le jeu depasse x1.25 avec ce
    -- reglage, il est remis a false automatiquement.
    fixed_fps    = 140,

    -- PLAY : neutralise la vraie souris et injecte a la place le deplacement
    -- de camera du REC, dans AddControllerYaw/PitchInput. La rotation
    -- rejouee arrive ainsi a la meme etape de la frame qu'en REC.
    camera_inject = true,

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
TAS_BUILD = "2026-09-10-21"

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
    SortFailLogged = false,

    -- Axes lus dans les hooks du PlayerController.
    Forward = 0.0,
    Right = 0.0,

    ----------------------------------------------------
    -- ENREGISTREUR / REJEU
    --
    -- Toutes ces cles existent des le chargement. B/N tournent sur le
    -- thread UE4SS : ils ne doivent QUE changer la valeur d'une cle deja
    -- presente. Inserer une cle depuis ce thread pourrait provoquer un
    -- rehash de la table pendant que le game thread la lit -- exactement
    -- la corruption constatee avec key_hooks.
    ----------------------------------------------------
    Mode = "idle",        -- "idle" | "rec" | "play"
    ModeRequest = false,  -- pose par B/N, consomme par le tick
    Rec = false,
    RecStart = 0,
    RecLast = false,
    PlayStart = 0,
    PlayState = false,
    PlayKeyState = false,
    PlayJump = false,
    PlayGait = false,
    ReplayOff = {},
    ReplayWarned = {},

    -- Sonde input (touche V), executee sur le game thread.
    ProbeStep = 0,
    ProbeFrame = 0,
    ProbeActive = false,
    ProbeForm = false,
    ProbeKeys = {},

    -- Logs de diagnostic
    DbgWatch = {},
    DbgKeys = {},
    DbgKeyForm = false,
    DbgKeyOff = false,
    DbgLastValue = {},

    -- Rejeu par les actions du jeu
    PlayKeys = false,
    PlayByKeys = false,

    -- Rejeu des axes par GetInputAxisValue
    AxisOverride = false,
    AxisPendingName = false,
    AxisOverrideWarned = false,

    -- Diagnostic et rejeu du sprint
    DbgWindow = false,
    GaitHookSeen = {},
    GaitHookLast = {},
    GaitOverrideLast = false
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
local recorder_tick

-- Diagnostic REC / PLAY (voir "DIAGNOSTIC" plus bas). Table separee de TAS :
-- seuls le game thread et les hooks y ecrivent, jamais un keybind.
local DIAG = {
    calls = {},          -- nom -> appels depuis le dernier tick
    prev_sig = false,    -- trace de la frame precedente
    rec_trace = {},      -- frame REC -> trace
    rec_snaps = {},      -- frame REC -> instantane des variables
    rec_track = {},      -- frame REC -> position et vitesse
    snap_prev = false,
    snap_reason = false,
    props = false,       -- variables de Keith, resolues une fois
    first_diff = {},
    first_order = {},
    trace_diffs = 0,
    trace_first = false,
    drift_level = 0,
    drift_first = false,
    last_ms = false,
    has_ref = false,
    pending_sig = false, -- trace coupee en debut de tick, par diag_cut
    desired_last = false,
    dt_off = false,      -- GetWorldDeltaSeconds indisponible
    dt_n = 0,
    dt_min = 0,
    dt_max = 0,
    dt_irregular = 0,
    dt_diffs = 0,
    t_wall = false,      -- mesure de vitesse, par time_report
    t_frame = 0,
    engine = false,      -- GameEngine, si le pas fixe a ete applique
    fixed_on = false,
    axis_seen = {},      -- axes demandes par le jeu via GetInputAxisValue
    scale_last = false   -- derniers parametres de ScaleProjectedObject
}

-- Injection camera en PLAY (voir apply_camera et install_camera_hooks).
local CAM = {
    frame = -1,          -- TAS.Frame du dernier apply_camera
    dyaw = 0,            -- deplacement a injecter pendant cette frame
    dpitch = 0,
    yaw_frame = -1,      -- frame deja servie, par axe
    pitch_frame = -1,
    yaw_scale = 2.5,     -- PlayerController.InputYawScale / InputPitchScale
    pitch_scale = -2.5,
    scales_read = false,
    calls = 0,
    leaks = 0,
    ecarts = 0
}

local function diag_count(name)
    local calls = DIAG.calls
    calls[name] = (calls[name] or 0) + 1
end

local diag_tick
local diag_begin
local diag_end
local diag_cut
local capture_keith
local restore_keith
local time_report

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

    TAS.TextInput = create_text(
        widget_tree,
        panel,
        "TAS_Input",
        8,
        76,
        400,
        22
    )

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

local function update_input_text()

    if not TAS.Visible then
        return
    end

    set_text("Input", TAS.TextInput,
        string.format("I F %.2f | R %.2f", TAS.Forward, TAS.Right))
end

-- Etat de l'enregistreur, affiche a la place des touches sur la ligne E.
local function recorder_status()

    if TAS.Mode == "rec" then
        return string.format("REC %05d | %d evts",
            TAS.Frame - TAS.RecStart, TAS.Rec.count)
    end

    if TAS.Mode == "play" then
        return string.format("PLAY %05d / %05d",
            TAS.Frame - TAS.PlayStart, TAS.Rec.length)
    end

    return nil
end

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
        right = "B rec | N play"
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

    local status = recorder_status()

    if status then
        line = "E " .. status
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
    -- Mesure du 10/09 : MovementState vaut 3 pendant une escalade
    -- (MovementAction = HighMantle). L'ordre lu dans le .uexp etait faux.
    [3] = "Mantling",
    [4] = "Ragdoll"
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
    update_input_text()
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
            -- Les touches du mod (B N L U Y I) ont leur propre binding.
            ------------------------------------------------

            if GAMEPLAY_KEYS[key_name]
            and key_code ~= Key.L
            and key_code ~= Key.U
            and key_code ~= Key.Y
            and key_code ~= Key.I
            and key_code ~= Key.B
            and key_code ~= Key.N
            and key_code ~= Key.V then

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

    recorder_tick()

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

    update_input_text()
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

--------------------------------------------------------
-- ENREGISTREUR ET REJEU D'INPUTS
--
-- Dictionnaire creux, indexe par numero de frame RELATIF au debut de
-- l'enregistrement :
--
--   events[0] = etat complet de tous les canaux
--   events[f] = uniquement les canaux qui changent a la frame f
--
-- Un "press" est une transition 0 -> 1, un "unpress" 1 -> 0 : seules les
-- transitions sont stockees.
--
-- Tous les canaux sont lus sur le GAME THREAD, jamais via RegisterKeyBind
-- (ses callbacks corrompent le tas Lua, cf. rapport de session) :
--
--   MoveForward / MoveRight    hooks d'axe du PlayerController (ZQSD)
--   Jump                       ACharacter.bPressedJump, scrute (Espace)
--   Gait                       DesiredGait ALS, 2 = Sprinting (Shift)
--   SprintHeld / RunHeld       booleens "Shift tenu" de Keith : l'input
--                              reel, dont Gait n'est que la consequence
--   CamPitch / CamYaw / CamRoll  rotation du controleur (souris)
--
-- Le saut et le sprint sont des ACTIONS Blueprint de Keith, dont les hooks
-- ne se declenchent jamais : on les lit donc par leur effet sur le pawn.
--
-- Rejeu des axes : Keith est un personnage ALS v4, dont PlayerMovementInput
-- ignore le parametre de l'evenement d'axe et relit les axes lui-meme via
-- GetInputAxisValue. Reecrire ce parametre (AxisValue:Set) reussissait sans
-- aucun effet -- mesure du 10/09. On reproduit donc ce que fait ALS :
-- AddMovementInput dans la direction du controleur (lacet seul), appele
-- depuis le hook d'axe, au meme moment du frame que le jeu. La
-- camera est imposee a chaque frame : MoveForward etant relatif a la
-- rotation du controleur, rejouer les axes sans elle ferait diverger
-- les deplacements des la premiere frame.
--
-- Chaque canal de rejeu se desactive au premier echec au lieu de reessayer
-- en boucle : une erreur Lua par frame suffit a faire planter UE4SS.
--------------------------------------------------------

-- Emplacement de l'enregistrement.
--
-- Le jeu tourne avec Binaries/Win64 comme repertoire courant : mesure du
-- 10/09, ou le fichier ecrit sans chemin y a atterri. debug.getinfo ne
-- rend pas de chemin exploitable dans ce build d'UE4SS, on vise donc le
-- dossier du mod en relatif a Win64 -- valable quel que soit le disque.
local RECORDING_FILE = "Mods/ShutterTASDiscovery/Scripts/last_recording.lua"

-- Emplacement utilise par le build 2026-09-10-2 : relu en secours, pour
-- ne pas perdre les prises faites avec.
local LEGACY_RECORDING_FILE = "last_recording.lua"

----------------------------------------------------------
-- Logs de diagnostic
--
-- Chaque ligne porte la frame absolue, et la frame relative a
-- l'enregistrement ou au rejeu : on peut aligner les deux ligne a ligne.
----------------------------------------------------------

local function dbg(fmt, ...)

    if not TAS_CONFIG.debug_log then return end

    local rel = ""

    if TAS.Mode == "rec" then
        rel = string.format(" rec=%d", TAS.Frame - TAS.RecStart)
    elseif TAS.Mode == "play" then
        rel = string.format(" play=%d", TAS.Frame - TAS.PlayStart)
    end

    local ok, text = pcall(string.format, fmt, ...)

    log(string.format("[DBG f=%d%s] %s", TAS.Frame, rel, ok and text or fmt))
end

local function record_value(channel, value)

    if TAS.Mode ~= "rec" or value == nil then
        return
    end

    if TAS.RecLast[channel] == value then
        return
    end

    TAS.RecLast[channel] = value

    local frame = TAS.Frame - TAS.RecStart
    local entry = TAS.Rec.events[frame]

    if not entry then
        entry = {}
        TAS.Rec.events[frame] = entry
    end

    entry[channel] = value
    TAS.Rec.count = TAS.Rec.count + 1

    dbg("REC %s = %s", channel, tostring(value))
end

-- FKey = struct { KeyName : FName } ; UE4SS convertit une table en struct.
local KEY_FORMS = {
    { "table {KeyName = FName}", function(c, n) return c:IsInputKeyDown({ KeyName = FName(n) }) end },
    { "FName seul",             function(c, n) return c:IsInputKeyDown(FName(n)) end },
    { "chaine seule",           function(c, n) return c:IsInputKeyDown(n) end }
}

----------------------------------------------------------
-- TOUCHES ET ACTIONS DU JEU
--
-- Mesure du 10/09 : IsInputKeyDown({ KeyName = FName(...) }) donne l'etat
-- reel de n'importe quelle touche, sur le game thread. On enregistre donc
-- les TOUCHES elles-memes -- les press / unpress de la mission -- au lieu
-- de leurs effets :
--   - l'escalade ne laissait aucune trace (bPressedJump reste a false quand
--     ALS choisit d'escalader au lieu de sauter) ;
--   - RunHeld n'est pas "Shift tenu" mais un resultat calcule ~34 frames
--     apres l'appui (Shift rec=66 -> RunHeld rec=100) : l'ecrire ne
--     declenche pas la logique qui le produit.
--
-- Au rejeu, on declenche les ACTIONS du jeu aux frames enregistrees : le
-- jeu fait lui-meme le choix escalade / saut, et gere le delai du sprint.
-- Hypothese a verifier en jeu : index bas = appui, index haut = relachement.
----------------------------------------------------------

local KEYS_RECORDED = {
    { "KeySpaceBar",   "SpaceBar" },
    { "KeyLeftShift",  "LeftShift" },
    { "KeyRightShift", "RightShift" },
    { "KeyE",          "E" },
    { "KeyLMB",        "LeftMouseButton" },
    { "KeyRMB",        "RightMouseButton" },
    { "KeyMMB",        "MiddleMouseButton" }
}

local KEITH_EVENT = "InpActEvt_%s_K2Node_InputActionEvent_%d"

-- Correspondance Config/DefaultInput.ini du pak. Interact, Shoot et Aim
-- n'exposent qu'une fonction (l'appui) : pas de relachement a rejouer.
local ACTION_BY_KEY = {
    KeySpaceBar   = { key = "SpaceBar",          press = KEITH_EVENT:format("JumpAction", 8),      release = KEITH_EVENT:format("JumpAction", 9) },
    KeyLeftShift  = { key = "LeftShift",         press = KEITH_EVENT:format("RunAction", 0),       release = KEITH_EVENT:format("RunAction", 1) },
    KeyRightShift = { key = "RightShift",        press = KEITH_EVENT:format("RunAction", 0),       release = KEITH_EVENT:format("RunAction", 1) },
    KeyMMB        = { key = "MiddleMouseButton", press = KEITH_EVENT:format("ObjectScaleMode", 2), release = KEITH_EVENT:format("ObjectScaleMode", 3) },
    KeyE          = { key = "E",                 press = KEITH_EVENT:format("Interact", 7) },
    KeyLMB        = { key = "LeftMouseButton",   press = KEITH_EVENT:format("Shoot", 5) },
    KeyRMB        = { key = "RightMouseButton",  press = KEITH_EVENT:format("Aim", 4) }
}

-- Evenements d'axe souris de Keith (10/09, build -21). Le redimensionnement
-- d'un objet (molette tenue + souris haut/bas) lit la valeur passee a
-- l'evenement LookUp/Down, pas GetInputAxisValue (mesure : le jeu n'y demande
-- que MoveForward et MoveRight). Ces stubs d'axe, eux, se declenchent bien.
local LOOK_EVENTS = {
    LookUpDown = "InpAxisEvt_LookUp/Down_K2Node_InputAxisEvent_2",
    LookLeftRight = "InpAxisEvt_LookLeft/Right_K2Node_InputAxisEvent_3"
}

-- Forme d'appel de IsInputKeyDown, resolue une seule fois.
local function key_form()

    if TAS.DbgKeyOff then return nil end

    if TAS.DbgKeyForm then return KEY_FORMS[TAS.DbgKeyForm] end

    local controller = get_player_controller()

    if not controller then return nil end

    for index, form in ipairs(KEY_FORMS) do
        local ok, value = pcall(form[2], controller, "SpaceBar")
        dbg("TOUCHES forme %s -> %s", form[1],
            ok and (type(value) .. " " .. tostring(value)) or ("ERREUR " .. tostring(value)))
        if ok and type(value) == "boolean" then
            TAS.DbgKeyForm = index
            return form
        end
    end

    TAS.DbgKeyOff = true
    log("IsInputKeyDown ne repond pas : touches non enregistrees")

    return nil
end

local function poll_keys()

    local form = key_form()

    if not form then return end

    local controller = get_player_controller()

    if not controller then return end

    for _, entry in ipairs(KEYS_RECORDED) do
        local ok, down = pcall(form[2], controller, entry[2])
        if ok and type(down) == "boolean" then
            record_value(entry[1], down)
        end
    end
end

-- Declenche une action de Keith, comme le ferait la vraie touche.
local function fire_action(fn, key_name)

    if TAS.ReplayOff.Actions then return false end

    local pawn = get_player_pawn()

    if not pawn then return false end

    local ok, err = pcall(function()
        pawn[fn](pawn, { KeyName = FName(key_name) })
    end)

    dbg("ACTION %s (%s) -> %s", fn, key_name, ok and "ok" or ("ERREUR " .. tostring(err)))

    if not ok then
        TAS.ReplayOff.Actions = true
        log("Appel des actions du jeu impossible : repli sur Jump() et RunHeld")
    end

    return ok
end

-- Touches vues avec une frame d'avance (voir replay_step).
local function merge_keys(entry)

    if not entry then return end

    for channel in pairs(ACTION_BY_KEY) do
        if entry[channel] ~= nil then
            TAS.PlayKeyState[channel] = entry[channel]
        end
    end

    -- DesiredGait note a la frame f+1 = etat a la fin de la frame f : meme
    -- avance d'une frame. Utilise par le hook ResetWalkingGait.
    if entry.Gait ~= nil then
        TAS.PlayKeyState.Gait = entry.Gait
    end
end

local function replay_keys()

    local state = TAS.PlayKeyState

    for channel, action in pairs(ACTION_BY_KEY) do

        local want = state[channel]
        local previous = TAS.PlayKeys[channel]

        if want ~= nil and want ~= previous then

            TAS.PlayKeys[channel] = want

            -- Frame 0 : une touche relachee n'a rien a declencher.
            if previous ~= nil or want == true then
                local fn = want and action.press or action.release
                if fn then
                    fire_action(fn, action.key)
                end
            end
        end
    end
end

-- Fin de rejeu : relacher les touches encore tenues.
local function release_keys()

    if not TAS.PlayKeys or TAS.ReplayOff.Actions then return end

    for channel, held in pairs(TAS.PlayKeys) do
        local action = ACTION_BY_KEY[channel]
        if held and action and action.release then
            fire_action(action.release, action.key)
        end
    end

    TAS.PlayKeys = {}
end

----------------------------------------------------------
-- REJEU DES AXES PAR GetInputAxisValue
--
-- Mesure du 10/09 : pendant le rejeu, ALS saute au lieu d'escalader, et le
-- sprint retombe des la frame qui suit son declenchement (play=104 -> 105),
-- alors que tout se passe bien a l'enregistrement. Seule difference : le jeu
-- relit l'etat brut des axes avec GetInputAxisValue (GetPlayerMovementInput,
-- PlayerMovementInput), qui renvoie 0 puisque personne ne touche au clavier.
-- AddMovementInput deplace Keith, mais ne change pas ce que le jeu croit que
-- le joueur fait : ALS n'escalade que si l'on pousse vers le rebord.
--
-- On hooke donc la fonction native elle-meme et on remplace sa valeur de
-- retour pendant le rejeu. Pour un chemin /Script/, le 2e argument de
-- RegisterHook est un pre-hook et le 3e un post-hook ; la valeur renvoyee
-- par le callback remplace la valeur de retour
-- (Docs/lua-api/global-functions/registerhook.md). Le changelog indique aussi
-- que le post-hook recoit la valeur de retour en 2e parametre : on fait les
-- deux, et on RELIT le resultat (verify_axis_override) avant de s'y fier.
----------------------------------------------------------

local AXIS_BY_NAME = {
    ["MoveForward/Backwards"] = "MoveForward",
    ["MoveRight/Left"] = "MoveRight"
}

-- Axes souris (10/09, build -20) : le redimensionnement d'un objet (molette
-- tenue + souris haut/bas) lit la souris par GetInputAxisValue, et rien ne
-- l'enregistrait. Ils sont enregistres depuis la valeur que le jeu obtient
-- (post-hook en REC), puis rejoues par le meme hook ; 0 si la prise n'a rien
-- a cette frame, pour que la vraie souris ne pilote rien en PLAY.
local AXIS_MOUSE = {
    ["LookUp/Down"] = "LookUpDown",
    ["LookLeft/Right"] = "LookLeftRight",
    ["MoveMouse"] = "MoveMouse"
}

local MOUSE_CHANNELS = {}

for _, channel in pairs(AXIS_MOUSE) do
    MOUSE_CHANNELS[channel] = true
end

local AxisOverrideInstalled = false

local function install_axis_override()

    if AxisOverrideInstalled then return end
    AxisOverrideInstalled = true

    local ok, err = pcall(function()
        RegisterHook(
            "/Script/Engine.Actor:GetInputAxisValue",

            -- pre : quel axe est demande ? REC : axes souris a enregistrer ;
            -- PLAY : tous les axes rejoues ; repos : ne rien toucher.
            function(Context, InputAxisName)

                TAS.AxisPendingName = false

                if TAS.Mode == "idle" then return end

                local ok_name, name = pcall(function()
                    return InputAxisName:get():ToString()
                end)

                if not ok_name or type(name) ~= "string" then return end

                diag_count("AXIS:" .. name)

                if not DIAG.axis_seen[name] then
                    DIAG.axis_seen[name] = true
                    dbg("AXE demande par le jeu : %s", name)
                end

                if TAS.Mode == "play" then
                    TAS.AxisPendingName = AXIS_BY_NAME[name] or AXIS_MOUSE[name] or false
                else
                    TAS.AxisPendingName = AXIS_MOUSE[name] or false
                end
            end,

            -- post : remplacer la valeur de retour
            function(Context, ReturnValue)
                local channel = TAS.AxisPendingName
                TAS.AxisPendingName = false

                if not channel then return nil end

                -- REC : la valeur que le jeu obtient (axes souris seulement)
                if TAS.Mode == "rec" then
                    local ok_rv, current = pcall(function() return ReturnValue:get() end)
                    if ok_rv and type(current) == "number" then
                        record_value(channel, current)
                    end
                    return nil
                end

                if TAS.Mode ~= "play" or not TAS.PlayState then
                    return nil
                end

                local replay = TAS.PlayState[channel]

                if replay == nil then
                    if not MOUSE_CHANNELS[channel] then return nil end
                    replay = 0
                end

                -- Mecanisme du changelog, seulement si c'est bien un nombre
                local ok_rv, current = pcall(function() return ReturnValue:get() end)
                if ok_rv and type(current) == "number" then
                    pcall(function() ReturnValue:set(replay) end)
                end

                -- Mecanisme de la doc
                return replay
            end
        )
    end)

    if ok then
        TAS.AxisOverride = true
        log("Hook GetInputAxisValue installe : le jeu rejouera les axes lui-meme")
    else
        log("Hook GetInputAxisValue impossible : " .. tostring(err)
            .. " -- repli sur AddMovementInput")
    end
end

-- Relit ce que le jeu obtient reellement. Si le remplacement ne prend pas,
-- on revient a AddMovementInput plutot que de laisser Keith immobile.
local function verify_axis_override()

    if not TAS.AxisOverride then return end

    local want = TAS.PlayState and TAS.PlayState.MoveForward

    if want == nil then return end

    local pawn = get_player_pawn()

    if not pawn then return end

    local ok, got = pcall(function()
        return pawn:GetInputAxisValue(FName("MoveForward/Backwards"))
    end)

    dbg("VERIF GetInputAxisValue(MoveForward) = %s, rejoue %s",
        ok and tostring(got) or "ERREUR", tostring(want))

    if ok and type(got) == "number" and math.abs(got - want) > 0.001 then
        TAS.AxisOverride = false
        if not TAS.AxisOverrideWarned then
            TAS.AxisOverrideWarned = true
            log(string.format("GetInputAxisValue renvoie %s au lieu de %s : "
                .. "le hook ne remplace pas la valeur, repli sur AddMovementInput",
                tostring(got), tostring(want)))
        end
    end
end

-- Canaux scrutes chaque frame pendant l'enregistrement.
local function poll_channels()

    local pawn = get_player_pawn()

    if pawn then

        local jump = read_field(pawn, "bPressedJump")

        if type(jump) == "boolean" then
            record_value("Jump", jump)
        end

        local gait = read_field(pawn, "DesiredGait")

        if type(gait) == "number" then
            record_value("Gait", gait)
        end

        -- Allure REELLE (le canal "Gait" ci-dessus est l'allure demandee).
        -- Sert au rejeu du sprint : c'est elle qu'on veut reproduire.
        local actual = read_field(pawn, "Gait")

        if type(actual) == "number" then
            record_value("GaitActual", actual)
        end

        -- Shutter pilote le sprint par des booleens tenus (table de noms de
        -- Keith_BP) et recalcule l'allure a partir d'eux : ecrire DesiredGait
        -- seul reussissait sans effet (mesure du 10/09). On enregistre donc
        -- l'input reel. Un nom qui n'est pas un membre rend un TrivialObject,
        -- pas un booleen, et n'est simplement pas enregistre.
        for _, name in ipairs({ "SprintHeld", "RunHeld" }) do
            local held = read_field(pawn, name)
            if type(held) == "boolean" then
                record_value(name, held)
            end
        end
    end

    local controller = get_player_controller()

    if controller then

        local ok, rotation = pcall(function()
            return controller:GetControlRotation()
        end)

        if ok then
            local pitch, yaw, roll = rotator_pyr(rotation)
            if pitch then
                record_value("CamPitch", pitch)
                record_value("CamYaw", yaw)
                record_value("CamRoll", roll)
            end
        end
    end

    poll_keys()
end

-- Pose de depart : sans elle, le rejeu part d'ailleurs et diverge.
local function capture_pose()

    local pawn = get_player_pawn()

    if not pawn then
        return nil
    end

    local pose = {}

    local x, y, z = get_player_location(pawn)

    if x then
        pose.x, pose.y, pose.z = x, y, z
    end

    local ok, rotation = pcall(function()
        return pawn:K2_GetActorRotation()
    end)

    if ok then
        local pitch, yaw, roll = rotator_pyr(rotation)
        if pitch then
            pose.pitch, pose.yaw, pose.roll = pitch, yaw, roll
        end
    end

    -- Saut, 10/09 : en REC le timeline JumpGravity de Keith a joue au 1er
    -- saut (pos 0 -> 0.329, gravite ~1.0) puis est reste en fin de course
    -- aux sauts suivants (gravite 1.8). En rejeu il etait deja en fin : 1er
    -- saut en gravite 1.8, atterrissage 15 frames trop tot. Son etat fait
    -- donc partie de la pose de depart.
    local timeline = read_field(pawn, "JumpGravity")

    if is_alive(timeline) then
        pcall(function()
            pose.tl_pos = timeline:GetPlaybackPosition()
            pose.tl_playing = timeline:IsPlaying()
            pose.tl_reverse = timeline:IsReversing()
        end)
    end

    local cmc = read_field(pawn, "CharacterMovement")
    local gravity = is_alive(cmc) and read_field(cmc, "GravityScale") or nil

    if type(gravity) == "number" then
        pose.gravity = gravity
    end

    pose.keith = capture_keith(pawn)

    dbg("POSE capturee : JumpGravity pos %s playing %s reverse %s | GravityScale %s",
        tostring(pose.tl_pos), tostring(pose.tl_playing),
        tostring(pose.tl_reverse), tostring(pose.gravity))

    return pose
end

local function restore_pose(pose)

    if not pose or not pose.x then
        return
    end

    local pawn = get_player_pawn()

    if not pawn then
        return
    end

    local target = { X = pose.x, Y = pose.y, Z = pose.z }
    local rotation = { Pitch = pose.pitch or 0, Yaw = pose.yaw or 0, Roll = pose.roll or 0 }

    local function offset()
        local x, y, z = get_player_location(pawn)
        if not x then return nil end
        return math.sqrt((x - pose.x) ^ 2 + (y - pose.y) ^ 2 + (z - pose.z) ^ 2), x, y, z
    end

    local ok, moved = pcall(function()
        return pawn:K2_TeleportTo(target, rotation)
    end)

    local method = "K2_TeleportTo"
    local distance = offset()

    -- 10/09, build -18 : K2_TeleportTo a refuse sans erreur (destination
    -- jugee bloquee), PLAY parti a 2540 unites. Il peut aussi decaler
    -- legerement Keith pour le degager. On force alors le placement exact.
    if not ok or moved == false or not distance or distance > 1e-4 then
        pcall(function()
            pawn:K2_SetActorLocationAndRotation(target, rotation, false, {}, true)
        end)
        method = "K2_SetActorLocationAndRotation force"
    end

    local final, x, y, z = offset()

    dbg("POSE position : visee %.4f %.4f %.4f | obtenue %s | ecart %s | %s (K2_TeleportTo a rendu %s)",
        pose.x, pose.y, pose.z,
        x and string.format("%.4f %.4f %.4f", x, y, z) or "?",
        final and string.format("%.5f", final) or "?",
        method, ok and tostring(moved) or "une erreur")

    if not final or final > 0.01 then
        log(string.format("POSE : position de depart NON restauree (ecart %s) : le rejeu va diverger",
            final and string.format("%.2f", final) or "?"))
    end

    -- Prises d'avant le 10/09 : pas d'etat de timeline, rien a restaurer.
    if pose.tl_pos then

        local timeline = read_field(pawn, "JumpGravity")

        if is_alive(timeline) then
            local ok_tl, err = pcall(function()
                timeline:Stop()
                timeline:SetPlaybackPosition(pose.tl_pos, false, false)
                if pose.tl_playing then
                    if pose.tl_reverse then timeline:Reverse() else timeline:Play() end
                end
            end)
            if not ok_tl then
                log("Timeline JumpGravity non restaure : " .. tostring(err))
            end
        end
    end

    if pose.gravity then
        local cmc = read_field(pawn, "CharacterMovement")
        if is_alive(cmc) then
            pcall(function() cmc.GravityScale = pose.gravity end)
        end
    end

    -- Relecture : ce que le jeu a vraiment pris
    local timeline = read_field(pawn, "JumpGravity")
    local t_pos, t_play = "-", "-"

    if is_alive(timeline) then
        pcall(function()
            t_pos = string.format("%.3f", timeline:GetPlaybackPosition())
            t_play = tostring(timeline:IsPlaying())
        end)
    end

    local cmc = read_field(pawn, "CharacterMovement")

    dbg("POSE restauree : JumpGravity pos %s playing %s (voulu %s %s) | GravityScale %s (voulu %s)",
        t_pos, t_play, tostring(pose.tl_pos), tostring(pose.tl_playing),
        tostring(is_alive(cmc) and read_field(cmc, "GravityScale") or nil),
        tostring(pose.gravity))

    -- Toutes les variables de Keith (JumpCounter compris) : voir capture_keith
    if pose.keith then
        restore_keith(pawn, pose.keith)
    end
end

----------------------------------------------------------
-- Ecriture / lecture du fichier
--
-- Format : un fichier Lua qui fait "return { ... }". Les flottants sont
-- ecrits en %.17g, ce qui preserve exactement un double : rejouer depuis
-- le fichier donne les memes valeurs que depuis la memoire.
----------------------------------------------------------

local function lua_value(value)

    local t = type(value)

    if t == "number" then
        if value == math.floor(value) and math.abs(value) < 1e15 then
            return string.format("%d", value)
        end
        return string.format("%.17g", value)
    end

    if t == "boolean" then
        return value and "true" or "false"
    end

    return string.format("%q", tostring(value))
end

-- Table imbriquee (etat de Keith) : cles texte, valeurs lua_value.
local function lua_table(t)

    local keys = {}

    for key in pairs(t) do
        keys[#keys + 1] = tostring(key)
    end

    table.sort(keys)

    local parts = {}

    for _, key in ipairs(keys) do
        local value = t[key]
        local text = type(value) == "table" and lua_table(value) or lua_value(value)
        parts[#parts + 1] = string.format("[%q] = %s", key, text)
    end

    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function save_recording(rec)

    local frames = {}

    for frame in pairs(rec.events) do
        frames[#frames + 1] = frame
    end

    table.sort(frames)

    local out = {
        "-- ShutterTAS : enregistrement d'inputs",
        "-- events[f] = canaux qui changent a la frame f (relative au debut)",
        "return {",
        string.format("    build = %q,", TAS_BUILD),
        string.format("    start_frame = %d,", rec.start_frame),
        string.format("    length = %d,", rec.length),
        string.format("    count = %d,", rec.count)
    }

    if rec.pose then
        local parts = {}
        for _, key in ipairs({ "x", "y", "z", "pitch", "yaw", "roll",
                               "tl_pos", "tl_playing", "tl_reverse", "gravity" }) do
            if rec.pose[key] then
                parts[#parts + 1] = key .. " = " .. lua_value(rec.pose[key])
            end
        end
        out[#out + 1] = "    pose = { " .. table.concat(parts, ", ") .. " },"
    end

    if rec.pose and rec.pose.keith then
        out[#out + 1] = "    keith = " .. lua_table(rec.pose.keith) .. ","
    end

    out[#out + 1] = "    events = {"

    for _, frame in ipairs(frames) do

        local entry = rec.events[frame]
        local keys = {}

        for key in pairs(entry) do
            keys[#keys + 1] = key
        end

        table.sort(keys)

        local parts = {}

        for _, key in ipairs(keys) do
            parts[#parts + 1] = key .. " = " .. lua_value(entry[key])
        end

        out[#out + 1] = string.format("        [%d] = { %s },",
            frame, table.concat(parts, ", "))
    end

    out[#out + 1] = "    },"
    out[#out + 1] = "}"

    local text = table.concat(out, "\n") .. "\n"

    -- Le dossier du mod d'abord ; Win64 en secours si son nom differe.
    for _, path in ipairs({ RECORDING_FILE, LEGACY_RECORDING_FILE }) do

        local ok, err = pcall(function()
            local file = assert(io.open(path, "w"))
            file:write(text)
            file:close()
        end)

        if ok then
            log("Enregistrement ecrit : " .. path)
            return
        end

        log("Ecriture impossible dans " .. path .. " : " .. tostring(err))
    end
end

local function load_recording()

    for _, path in ipairs({ RECORDING_FILE, LEGACY_RECORDING_FILE }) do

        local ok, rec = pcall(function()
            local chunk = loadfile(path)
            if not chunk then return nil end
            return chunk()
        end)

        if ok and type(rec) == "table" and type(rec.events) == "table" then
            if type(rec.keith) == "table" and type(rec.pose) == "table" then
                rec.pose.keith = rec.keith
            end
            log("Enregistrement charge : " .. path)
            return rec
        end
    end

    return nil
end

----------------------------------------------------------
-- Rejeu, canal par canal
----------------------------------------------------------

-- Ecart d'angle ramene dans [-180, 180].
local function angle_delta(from, to)
    local d = (to - from) % 360
    if d > 180 then d = d - 360 end
    return d
end

-- Camera, 10/09 : en REC, la souris tourne la camera PENDANT la frame
-- (UpdateRotation du PlayerController), apres la lecture des axes de
-- mouvement mais avant le tick de Keith. poll_channels, en debut de frame
-- suivante, voit donc en f+1 la rotation de la fin de la frame f.
--
-- On impose en debut de frame la rotation notee a f (celle que le
-- mouvement a vue en REC), puis on injecte l'ecart f -> f+1 dans
-- AddControllerYaw/PitchInput, a la place de la vraie souris : la frame se
-- termine sur la rotation notee a f+1, comme en REC.
local function apply_camera(frame)

    if TAS.ReplayOff.Camera then return end

    local state = TAS.PlayState

    if state.CamPitch == nil then return end

    local controller = get_player_controller()

    if not controller then return end

    if not CAM.scales_read then
        CAM.scales_read = true
        local yaw_scale = read_field(controller, "InputYawScale")
        local pitch_scale = read_field(controller, "InputPitchScale")
        if type(yaw_scale) == "number" and yaw_scale ~= 0 then CAM.yaw_scale = yaw_scale end
        if type(pitch_scale) == "number" and pitch_scale ~= 0 then CAM.pitch_scale = pitch_scale end
        log(string.format("Echelles souris : InputYawScale %s InputPitchScale %s",
            tostring(yaw_scale), tostring(pitch_scale)))
    end

    -- Controle : la frame precedente devait se terminer sur la rotation du
    -- REC a cette frame. Un ecart = injection ratee ou souris qui fuit.
    if frame and frame > 0 and CAM.ecarts < 100 then
        local ok_r, rotation = pcall(function() return controller:GetControlRotation() end)
        local pitch, yaw = nil, nil
        if ok_r then pitch, yaw = rotator_pyr(rotation) end
        if yaw and pitch then
            local dy = angle_delta(state.CamYaw, yaw)
            local dp = angle_delta(state.CamPitch, pitch)
            if math.abs(dy) > 1e-3 or math.abs(dp) > 1e-3 then
                CAM.ecarts = CAM.ecarts + 1
                dbg("CAMERA ecart en debut de frame : yaw %+.4f pitch %+.4f (REC %.4f / %.4f)",
                    dy, dp, state.CamYaw, state.CamPitch)
            end
        end
    end

    local ok = pcall(function()
        controller:SetControlRotation({
            Pitch = state.CamPitch,
            Yaw = state.CamYaw,
            Roll = state.CamRoll or 0
        })
    end)

    if not ok then
        TAS.ReplayOff.Camera = true
        log("SetControlRotation indisponible : camera non rejouee")
        return
    end

    if TAS_CONFIG.camera_inject and frame then
        local next_entry = TAS.Rec.events[frame + 1]
        local next_yaw = next_entry and next_entry.CamYaw or state.CamYaw
        local next_pitch = next_entry and next_entry.CamPitch or state.CamPitch
        CAM.dyaw = angle_delta(state.CamYaw, next_yaw)
        CAM.dpitch = angle_delta(state.CamPitch, next_pitch)
        CAM.frame = TAS.Frame
    end
end

local function apply_jump()

    if TAS.ReplayOff.Jump then return end

    local want = TAS.PlayState.Jump == true

    if want == TAS.PlayJump then return end

    local pawn = get_player_pawn()

    if not pawn then return end

    local ok = pcall(function()
        if want then pawn:Jump() else pawn:StopJumping() end
    end)

    dbg("JUMP %s -> %s", want and "Jump()" or "StopJumping()", ok and "ok" or "ERREUR")

    if ok then
        TAS.PlayJump = want
    else
        TAS.ReplayOff.Jump = true
        log("Jump() / StopJumping() indisponibles : saut non rejoue")
    end
end

-- Ecrit une propriete du pawn, et VERIFIE qu'elle a pris.
--
-- Deux fois le 10/09, une ecriture a "reussi" sans aucun effet
-- (AxisValue:Set, DesiredGait) : seule la relecture le prouve. Maintenu a
-- chaque frame, comme une touche tenue, car le Blueprint peut recalculer
-- la valeur derriere nous. On n'ecrit que si la valeur relue differe.
local function hold_field(pawn, name, want)

    if TAS.ReplayOff[name] then return end

    local before = read_field(pawn, name)

    if before == want then return end

    local ok = pcall(function()
        pawn[name] = want
    end)

    if not ok then
        TAS.ReplayOff[name] = true
        log("Ecriture de " .. name .. " impossible : canal desactive")
        return
    end

    local after = read_field(pawn, name)

    dbg("ECRIT %s : %s -> voulu %s, relu %s", name, tostring(before), tostring(want), tostring(after))

    if after ~= want and not TAS.ReplayWarned[name] then
        TAS.ReplayWarned[name] = true
        log(string.format("Ecriture de %s sans effet : voulu %s, relu %s",
            name, tostring(want), tostring(after)))
    end
end

local function apply_sprint()

    local pawn = get_player_pawn()

    if not pawn then return end

    local state = TAS.PlayState

    if state.SprintHeld ~= nil then hold_field(pawn, "SprintHeld", state.SprintHeld) end
    if state.RunHeld ~= nil then hold_field(pawn, "RunHeld", state.RunHeld) end
    if state.Gait ~= nil then hold_field(pawn, "DesiredGait", state.Gait) end
end

-- Fin de rejeu : relacher ce qu'on tenait, sinon Keith continue de sprinter.
local function release_sprint()

    local state = TAS.PlayState

    if not state then return end

    local pawn = get_player_pawn()

    if not pawn then return end

    pcall(function()
        if state.SprintHeld then pawn.SprintHeld = false end
        if state.RunHeld then pawn.RunHeld = false end
        if state.Gait == 2 then pawn.DesiredGait = 1 end
    end)
end

local function stop_replay(reason)

    release_sprint()
    release_keys()

    if TAS.PlayJump then
        local pawn = get_player_pawn()
        if pawn then
            pcall(function() pawn:StopJumping() end)
        end
    end

    diag_end("play")
    TAS.Mode = "idle"
    TAS.PlayState = false
    TAS.PlayJump = false
    TAS.PlayGait = false

    log("PLAY arrete (" .. reason .. ")")
end

-- PLAY : l'evenement d'axe recoit la vraie souris (0 en rejeu). On l'appelle
-- nous-memes avec la valeur du REC. Appele avant apply_camera : le
-- AddControllerPitchInput qu'il declenche recoit 0 (hook camera), donc la
-- camera reste celle de la prise.
local function replay_look()

    if DIAG.look_off then return end

    local pawn = get_player_pawn()

    if not pawn then return end

    for channel, fn in pairs(LOOK_EVENTS) do

        local value = TAS.PlayState[channel]

        if type(value) == "number" and value ~= 0 then

            local ok, err = pcall(function() pawn[fn](pawn, value) end)

            if not ok then
                DIAG.look_off = true
                log("Rejeu des axes souris impossible : " .. tostring(err))
                return
            end

            if TAS.PlayKeyState and TAS.PlayKeyState.KeyMMB then
                dbg("LOOK %s rejoue %.4f (molette tenue)", channel, value)
            end
        end
    end
end

local function replay_step()

    local rec = TAS.Rec
    local frame = TAS.Frame - TAS.PlayStart

    if frame > rec.length then
        stop_replay("fin de l'enregistrement")
        return
    end

    local entry = rec.events[frame]

    if entry then
        for channel, value in pairs(entry) do
            TAS.PlayState[channel] = value
        end
    end

    -- Le jeu lit-il bien la valeur rejouee ? A chaque changement de l'axe
    -- avant, et toutes les 30 frames.
    if (entry and entry.MoveForward ~= nil) or frame % 30 == 0 then
        verify_axis_override()
    end

    -- Touches : poll_keys les lit AVANT que le jeu traite les entrees de la
    -- frame, donc le jeu a agi une frame plus tot que la frame notee
    -- (10/09 : Character:Jump a 158, KeySpaceBar = true a 159 ; rejouee a
    -- 159, toute la trajectoire avait 1 frame de retard). On declenche
    -- l'action avec une frame d'avance. Les axes et la camera, eux, sont
    -- notes et relus dans la meme frame : pas de decalage.
    if frame == 0 then
        merge_keys(rec.events[0])
    end

    merge_keys(rec.events[frame + 1])

    -- Prise avec touches : on declenche les actions du jeu. Sinon (ancienne
    -- prise, ou actions impossibles a appeler) : repli sur les effets.
    if TAS.PlayByKeys and not TAS.ReplayOff.Actions then
        replay_keys()
    else
        apply_jump()
        apply_sprint()
    end

    replay_look()

    apply_camera(frame)
end

----------------------------------------------------------
-- Transitions d'etat (toujours executees sur le game thread)
----------------------------------------------------------

-- Resume d'une prise : canaux, nombre de valeurs, premiere transition.
local function dump_recording(rec)

    if not TAS_CONFIG.debug_log or not rec then return end

    local counts, first = {}, {}

    for frame, entry in pairs(rec.events) do
        for channel in pairs(entry) do
            counts[channel] = (counts[channel] or 0) + 1
            if frame > 0 and (first[channel] == nil or frame < first[channel]) then
                first[channel] = frame
            end
        end
    end

    local names = {}

    for channel in pairs(counts) do
        names[#names + 1] = channel
    end

    table.sort(names)

    for _, channel in ipairs(names) do
        dbg("CONTENU %-11s %4d valeurs, 1re transition frame %s",
            channel, counts[channel], tostring(first[channel]))
    end
end

local function start_recording()

    TAS.Rec = {
        events = {},
        count = 0,
        length = 0,
        start_frame = TAS.Frame,
        pose = capture_pose()
    }

    TAS.RecStart = TAS.Frame
    TAS.RecLast = {}
    TAS.Mode = "rec"
    TAS.DbgWatch = {}
    TAS.DbgKeys = {}

    -- frame 0 : etat complet
    record_value("MoveForward", TAS.Forward)
    record_value("MoveRight", TAS.Right)
    poll_channels()

    diag_begin("rec")

    log("REC demarre a la frame " .. tostring(TAS.Frame))
end

local function stop_recording()

    TAS.Rec.length = TAS.Frame - TAS.RecStart
    diag_end("rec")
    TAS.Mode = "idle"

    log(string.format("REC arrete : %d frames, %d evenements",
        TAS.Rec.length, TAS.Rec.count))

    dump_recording(TAS.Rec)

    save_recording(TAS.Rec)
end

local function start_replay()

    local rec = TAS.Rec

    if not rec then
        rec = load_recording()
    end

    if not rec or not rec.events[0] then
        log("Rien a rejouer : enregistre d'abord avec B")
        return
    end

    TAS.Rec = rec
    TAS.PlayState = {}
    TAS.PlayJump = false
    TAS.PlayGait = false
    TAS.ReplayWarned = {}
    TAS.PlayKeys = {}
    TAS.PlayKeyState = {}
    CAM.calls, CAM.leaks, CAM.ecarts = 0, 0, 0
    CAM.frame, CAM.yaw_frame, CAM.pitch_frame = -1, -1, -1
    TAS.PlayByKeys =rec.events[0] ~= nil and rec.events[0].KeySpaceBar ~= nil

    log(TAS.PlayByKeys
        and "Rejeu des actions : touches -> actions du jeu"
        or "Rejeu des actions : prise sans touches, repli sur les effets")
    TAS.PlayStart = TAS.Frame

    restore_pose(rec.pose)

    TAS.Mode = "play"
    TAS.DbgWatch = {}
    TAS.DbgKeys = {}
    TAS.DbgLastValue = {}

    diag_begin("play")

    log(string.format("PLAY demarre : %d frames, %s evenements",
        rec.length, tostring(rec.count)))

    dump_recording(rec)

    replay_step()
end

----------------------------------------------------------
-- SONDE INPUT (touche V), en trois etapes successives
--
-- Le 10/09, le sprint et l'escalade ne se rejouent pas : on reproduit leurs
-- EFFETS (bPressedJump, RunHeld, DesiredGait) au lieu de declencher les
-- ACTIONS du jeu. ALS choisit entre escalade et saut dans le handler de
-- JumpAction (MantleCheck) : appeler Jump() le contourne, et bPressedJump
-- ne passe meme pas a true sur une escalade, qui n'est donc pas enregistree.
--
-- Deux inconnues, que seul le jeu peut trancher :
--   1. IsInputKeyDown(FKey) repond-il ? -> enregistrement fiable des touches,
--      scrute sur le game thread, sans RegisterKeyBind.
--   2. Appeler les handlers InpActEvt_* de Keith declenche-t-il l'action ?
--      Et quel index est l'appui, lequel le relachement ?
--
-- Tout tourne dans recorder_tick (game thread). Les formes d'appel sont
-- essayees UNE fois au debut de l'etape, jamais en boucle.
----------------------------------------------------------

local PROBE_KEYS = { "SpaceBar", "LeftShift", "E", "LeftMouseButton", "RightMouseButton" }


local function resolve_key_form()

    local controller = get_player_controller()

    if not controller then
        log("  pas de controleur")
        return false
    end

    local ok_name, text = pcall(function()
        return FName("SpaceBar"):ToString()
    end)

    log("  FName(\"SpaceBar\") -> " .. (ok_name and tostring(text) or "ERREUR"))

    for index, form in ipairs(KEY_FORMS) do

        local ok, value = pcall(form[2], controller, "SpaceBar")

        log(string.format("  forme %-24s -> %s", form[1],
            ok and (type(value) .. " " .. tostring(value))
               or ("ERREUR " .. tostring(value))))

        if ok and type(value) == "boolean" then
            TAS.ProbeForm = index
            return true
        end
    end

    log("  aucune forme d'appel de IsInputKeyDown ne repond")
    return false
end

local function key_down(controller, name)

    local form = KEY_FORMS[TAS.ProbeForm]

    if not form then return nil end

    local ok, value = pcall(form[2], controller, name)

    if ok and type(value) == "boolean" then
        return value
    end

    return nil
end

local function call_event(fn, key_name)

    local pawn = get_player_pawn()

    if not pawn then
        log("  pas de pawn")
        return
    end

    local ok, err = pcall(function()
        pawn[fn](pawn, { KeyName = FName(key_name) })
    end)

    log(string.format("  %s -> %s", fn, ok and "ok" or ("ERREUR " .. tostring(err))))
end

local function probe_start()

    if TAS.Mode ~= "idle" then
        log("Sonde refusee : enregistrement ou rejeu en cours")
        return
    end

    TAS.ProbeStep = TAS.ProbeStep % 3 + 1
    TAS.ProbeFrame = TAS.Frame
    TAS.ProbeActive = true

    if TAS.ProbeStep == 1 then
        log("SONDE 1/3 : presse Espace, Shift, E, clic gauche, clic droit (6 s)")
        TAS.ProbeKeys = {}
        if not resolve_key_form() then
            TAS.ProbeActive = false
        end
    elseif TAS.ProbeStep == 2 then
        log("SONDE 2/3 : JumpAction, appui (_8) puis relachement (_9) 15 frames plus tard")
        call_event("InpActEvt_JumpAction_K2Node_InputActionEvent_8", "SpaceBar")
    else
        log("SONDE 3/3 : RunAction, appui (_0) puis relachement (_1) 2 s plus tard -- avance pendant ce temps")
        call_event("InpActEvt_RunAction_K2Node_InputActionEvent_0", "LeftShift")
    end
end

local function probe_tick()

    local elapsed = TAS.Frame - TAS.ProbeFrame

    if TAS.ProbeStep == 1 then

        local controller = get_player_controller()

        if controller then
            for _, name in ipairs(PROBE_KEYS) do
                local down = key_down(controller, name)
                if down ~= nil and down ~= TAS.ProbeKeys[name] then
                    -- l'etat initial est memorise sans etre loggue
                    if TAS.ProbeKeys[name] ~= nil then
                        log(string.format("  frame %3d : %-16s %s",
                            elapsed, name, down and "APPUI" or "relache"))
                    end
                    TAS.ProbeKeys[name] = down
                end
            end
        end

        if elapsed >= 360 then
            TAS.ProbeActive = false
            log("SONDE 1/3 terminee")
        end

    elseif TAS.ProbeStep == 2 then

        if elapsed >= 15 then
            call_event("InpActEvt_JumpAction_K2Node_InputActionEvent_9", "SpaceBar")
            TAS.ProbeActive = false
            log("SONDE 2/3 terminee")
        end

    else

        if elapsed >= 120 then
            call_event("InpActEvt_RunAction_K2Node_InputActionEvent_1", "LeftShift")
            TAS.ProbeActive = false
            log("SONDE 3/3 terminee")
        end
    end
end

----------------------------------------------------------
-- Surveillance automatique pendant REC et PLAY
--
-- Etat du pawn et vraies touches, logues a chaque CHANGEMENT : complet a
-- la frame pres, sans ecrire 60 lignes par seconde pour rien.
----------------------------------------------------------

local WATCH_FIELDS = {
    "MovementState", "MovementAction", "Stance", "Gait", "AllowedGait",
    "DesiredGait", "RunHeld", "SprintHeld", "bPressedJump"
}

local DBG_KEYS = {
    "SpaceBar", "LeftShift", "E",
    "LeftMouseButton", "RightMouseButton", "MiddleMouseButton"
}

local function debug_watch()

    if not TAS_CONFIG.debug_log then return end

    local pawn = get_player_pawn()

    if pawn then

        for _, name in ipairs(WATCH_FIELDS) do

            local value = read_field(pawn, name)
            local t = type(value)

            -- TrivialObject = propriete absente : on le dit plutot que de masquer
            if t ~= "boolean" and t ~= "number" and t ~= "string" then
                value = "absent(" .. t .. ")"
            end

            if TAS.DbgWatch[name] ~= value then
                dbg("ETAT %-14s %s -> %s", name, tostring(TAS.DbgWatch[name]), tostring(value))
                TAS.DbgWatch[name] = value
                -- Un changement d'allure ouvre une fenetre de 6 frames detaillees
                if name == "DesiredGait" or name == "Gait" then
                    TAS.DbgWindow = TAS.Frame + 6
                end
            end
        end

        -- Sprint, 10/09 : DesiredGait retombe a 1 la frame qui suit son passage
        -- a 2, en rejeu seulement. On compare REC et PLAY frame par frame.
        if TAS.DbgWindow and TAS.Frame <= TAS.DbgWindow then
            local function field(name)
                local x = read_field(pawn, name)
                local t = type(x)
                if t == "number" or t == "boolean" then return tostring(x) end
                return "-"
            end
            dbg("FENETRE HasInput %s | InputAmount %s | IsMoving %s | RotMode %s | Speed %s | Gait %s | Desired %s | RunHeld %s",
                field("HasMovementInput"), field("MovementInputAmount"), field("IsMoving"),
                field("RotationMode"), field("Speed"), field("Gait"),
                field("DesiredGait"), field("RunHeld"))
        end

        -- Saut, 10/09 : physique en l'air, frame par frame. Ce dump a montre
        -- les deux causes d'ecart REC / PLAY : touches rejouees 1 frame en
        -- retard (corrige dans replay_step) et timeline JumpGravity dans un
        -- autre etat au depart (corrige dans capture_pose / restore_pose).
        if TAS.DbgWatch.MovementState == 2 then

            local ok_v, velocity = pcall(function() return pawn:GetVelocity() end)
            local vx, vy, vz = vector_xyz(ok_v and velocity or nil)

            local cmc = read_field(pawn, "CharacterMovement")
            local gravity = is_alive(cmc) and read_field(cmc, "GravityScale") or nil

            local t_pos, t_play, t_rev = "-", "-", "-"
            local timeline = read_field(pawn, "JumpGravity")

            if is_alive(timeline) then
                pcall(function()
                    t_pos = string.format("%.3f", timeline:GetPlaybackPosition())
                    t_play = tostring(timeline:IsPlaying())
                    t_rev = tostring(timeline:IsReversing())
                end)
            end

            dbg("AIR vz %s | vxy %s | grav %s | hold %s | force %s | pressed %s | JumpGravity pos %s playing %s reverse %s",
                vz and string.format("%.1f", vz) or "-",
                vx and string.format("%.1f", math.sqrt(vx * vx + vy * vy)) or "-",
                tostring(gravity),
                tostring(read_field(pawn, "JumpKeyHoldTime")),
                tostring(read_field(pawn, "JumpForceTimeRemaining")),
                tostring(read_field(pawn, "bPressedJump")),
                t_pos, t_play, t_rev)
        end

        if TAS.Frame % 15 == 0 then
            local x, y, z = get_player_location(pawn)
            dbg("POS %.1f %.1f %.1f | Speed %s | axes F %.2f R %.2f",
                x or 0, y or 0, z or 0,
                tostring(read_field(pawn, "Speed")), TAS.Forward, TAS.Right)
        end
    end

    -- En REC, les touches sont deja lues et loguees par poll_keys.
    if TAS.DbgKeyOff or TAS.Mode == "rec" then return end

    local controller = get_player_controller()

    if not controller then return end

    -- Forme d'appel de IsInputKeyDown resolue une seule fois
    if not TAS.DbgKeyForm then

        for index, form in ipairs(KEY_FORMS) do
            local ok, value = pcall(form[2], controller, "SpaceBar")
            dbg("TOUCHES forme %s -> %s", form[1],
                ok and (type(value) .. " " .. tostring(value)) or ("ERREUR " .. tostring(value)))
            if ok and type(value) == "boolean" then
                TAS.DbgKeyForm = index
                break
            end
        end

        if not TAS.DbgKeyForm then
            TAS.DbgKeyOff = true
            dbg("TOUCHES : IsInputKeyDown ne repond pas, surveillance des touches coupee")
            return
        end
    end

    local form = KEY_FORMS[TAS.DbgKeyForm]

    for _, name in ipairs(DBG_KEYS) do
        local ok, down = pcall(form[2], controller, name)
        if ok and type(down) == "boolean" and TAS.DbgKeys[name] ~= down then
            dbg("TOUCHE %-18s %s", name, down and "APPUI" or "relache")
            TAS.DbgKeys[name] = down
        end
    end
end

-- Appele a CHAQUE frame par tas_tick, avant le throttle du HUD :
-- enregistrer ou rejouer a 7 Hz n'aurait aucun sens.
function recorder_tick()

    time_report()

    local request = TAS.ModeRequest

    if request then

        TAS.ModeRequest = false

        if request == "rec" then
            if TAS.Mode == "idle" then
                start_recording()
                return
            elseif TAS.Mode == "rec" then
                stop_recording()
                return
            end
        elseif request == "play" then
            if TAS.Mode == "idle" then
                start_replay()
                return
            elseif TAS.Mode == "play" then
                stop_replay("N")
                return
            end
        elseif request == "probe" then
            probe_start()
            return
        end
    end

    if TAS.ProbeActive then
        probe_tick()
    end

    -- Trace coupee AVANT le rejeu : les actions declenchees par replay_step
    -- tombent dans la frame suivante, comme les vraies touches en REC.
    if TAS.Mode ~= "idle" then
        diag_cut()
    end

    if TAS.Mode == "rec" then
        poll_channels()
    elseif TAS.Mode == "play" then
        replay_step()
    end

    if TAS.Mode ~= "idle" then
        debug_watch()
        diag_tick()
    end
end

----------------------------------------------------------
-- Hooks d'axe : lecture, enregistrement, reinjection
----------------------------------------------------------

local AXIS_PATH = "/Game/Blueprints/GameMode/Shutter_PlayerController.Shutter_PlayerController_C:"

-- Reproduit ALS PlayerMovementInput : direction tiree du seul lacet de la
-- rotation du controleur, puis AddMovementInput avec la valeur de l'axe.
-- Le CharacterMovementComponent borne ensuite le vecteur cumule a 1, ce qui
-- regle les diagonales au clavier. FixDiagonalGamepadValues n'est pas
-- reproduit : sans effet sur les valeurs 0 / +-1 du clavier, il pourrait
-- faire diverger un enregistrement fait a la manette.
local function apply_movement(is_forward, value)

    local pawn = get_player_pawn()
    local controller = get_player_controller()

    if not pawn or not controller then
        return
    end

    local ok = pcall(function()

        local _, yaw_deg = rotator_pyr(controller:GetControlRotation())

        if not yaw_deg then
            error("rotation du controleur illisible")
        end

        local yaw = math.rad(yaw_deg)
        local direction

        if is_forward then
            direction = { X = math.cos(yaw), Y = math.sin(yaw), Z = 0 }
        else
            direction = { X = -math.sin(yaw), Y = math.cos(yaw), Z = 0 }
        end

        pawn:AddMovementInput(direction, value, false)

        local axis = is_forward and "F" or "R"
        local signature = string.format("%.2f %d", value, math.floor(yaw_deg))

        if TAS.DbgLastValue[axis] ~= signature then
            TAS.DbgLastValue[axis] = signature
            dbg("MOVE %s valeur %.2f yaw %.1f dir (%.3f, %.3f)",
                is_forward and "avant" or "cote", value, yaw_deg,
                direction.X, direction.Y)
        end
    end)

    if not ok then
        TAS.ReplayOff.Axis = true
        log("AddMovementInput indisponible : axes non rejoues")
    end
end

local function axis_hook(channel, field)

    return function(Context, AxisValue)

        -- RemoteUnrealParam:Get() est confirme sur
        local value = AxisValue:Get()

        TAS[field] = value
        TAS.AxisEvents = TAS.AxisEvents + 1

        if TAS.Mode == "rec" then

            record_value(channel, value)

        elseif TAS.Mode == "play" and not TAS.ReplayOff.Axis then

            local replay = TAS.PlayState[channel]

            if replay ~= nil then

                local pair = string.format("%.2f/%.2f", value, replay)

                if TAS.DbgLastValue[channel] ~= pair then
                    TAS.DbgLastValue[channel] = pair
                    dbg("AXE %s reel %.2f rejoue %.2f", channel, value, replay)
                end

                TAS[field] = replay

                -- 0 : rien a ajouter, et un appel C++ de moins
                -- Si GetInputAxisValue est remplace, c'est le jeu qui deplace
                -- Keith : ajouter AddMovementInput doublerait le mouvement.
                if replay ~= 0 and not TAS.AxisOverride then
                    apply_movement(channel == "MoveForward", replay)
                end
            end
        end
    end
end

local ForwardHookInstalled = false
local RightHookInstalled = false

local function install_forward_hook()

    if ForwardHookInstalled then return end
    ForwardHookInstalled = true

    if not TAS_CONFIG.axis_hooks then return end

    RegisterHook(
        AXIS_PATH .. "InpAxisEvt_MoveForward/Backwards_K2Node_InputAxisEvent_0",
        axis_hook("MoveForward", "Forward"))

    log("Forward axis hook installed")
end

local function install_right_hook()

    if RightHookInstalled then return end
    RightHookInstalled = true

    if not TAS_CONFIG.axis_hooks then return end

    RegisterHook(
        AXIS_PATH .. "InpAxisEvt_MoveRight/Left_K2Node_InputAxisEvent_1",
        axis_hook("MoveRight", "Right"))

    log("Right axis hook installed")
end

----------------------------------------------------------
-- FONCTIONS D'ALLURE DE KEITH : diagnostic + rejeu du sprint
--
-- Mesure du 10/09 : en rejeu, RunAction declenche bien le sprint
-- (DesiredGait 2 a play=119, delai du jeu compris), mais DesiredGait
-- retombe a 1 des play=120 alors que RunHeld reste a true. Les axes ne
-- sont plus en cause (VERIF GetInputAxisValue = valeur rejouee), et Keith
-- n'appelle pas IsInputKeyDown. Le pak montre ResetWalkingGait,
-- RetriggerableDelay, CanSprint, GetAllowedGait, BPI_Set_Gait : on hooke
-- ces fonctions pour voir QUI remet l'allure a 1.
--
-- Pour une fonction Blueprint, le callback s'execute APRES la fonction ;
-- s'il y a une valeur de retour, elle arrive en 2e parametre, et la valeur
-- renvoyee par le callback la remplace (Docs + Changelog v3.0.0).
--
-- CAUSE, mesuree le 10/09 : ResetWalkingGait est appelee a CHAQUE frame avec
-- en parametre la valeur de l'axe avant recue par l'evenement d'input de
-- Keith. Enregistrement : ResetWalkingGait(1.0) -> DesiredGait reste a 2.
-- Rejeu : ResetWalkingGait(0.0) -> DesiredGait retombe a 1. Ce parametre
-- vient du vrai clavier : remplacer GetInputAxisValue ne le change pas, et
-- un hook Blueprint s'execute trop tard pour le modifier.
--
-- Rejeu : on enregistre ce que GetAllowedGait REPOND pendant la prise (c'est
-- la valeur qu'ALS consulte pour choisir la vitesse), et on rejoue exactement
-- cette reponse aux memes frames. Meme principe que GetInputAxisValue : on
-- rejoue les reponses du jeu, pas leurs causes. Les prises plus anciennes,
-- sans ce canal, se rabattent sur l'allure reelle (GaitActual = 2).
--
-- Chaque hook signale son PREMIER appel, meme hors REC/PLAY : si aucun ne
-- tire jamais, les hooks sur Keith sont inoperants en general -- ce qui
-- expliquerait aussi le silence de ses InpActEvt depuis le 08/09.
----------------------------------------------------------

local KEITH_CLASS = "/Game/Characters/Keith/Keith_BP.Keith_BP_C:"

local GAIT_HOOKS = { "ResetWalkingGait", "BPI_Set_Gait", "OnGaitChanged", "CanSprint", "GetAllowedGait" }

local GaitHooksInstalled = false

local function param_text(param)
    if param == nil then return "-" end
    local ok, value = pcall(function() return param:get() end)
    if not ok then return "?" end
    return tostring(value)
end

local function install_gait_hooks()

    if GaitHooksInstalled then return end
    GaitHooksInstalled = true

    for _, name in ipairs(GAIT_HOOKS) do

        local fn = name

        local ok, err = pcall(function()
            RegisterHook(KEITH_CLASS .. fn, function(Context, First)

                if not TAS.GaitHookSeen[fn] then
                    TAS.GaitHookSeen[fn] = true
                    log("KEITH " .. fn .. " : premier appel constate")
                end

                local shown = param_text(First)

                if fn == "GetAllowedGait" then

                    local ok_rv, current = pcall(function() return First:get() end)
                    local numeric = ok_rv and type(current) == "number"

                    -- REC : la reponse du jeu, enregistree a chaque changement
                    if TAS.Mode == "rec" and numeric then
                        record_value("AllowedGait", current)
                    end

                    -- PLAY : on rejoue la reponse enregistree
                    if TAS.Mode == "play" and TAS.PlayState then

                        local want = TAS.PlayState.AllowedGait

                        if want == nil and TAS.PlayState.GaitActual == 2 then
                            want = 2   -- prise sans le canal AllowedGait
                        end

                        if want ~= nil then
                            if numeric and current ~= want then
                                pcall(function() First:set(want) end)
                            end
                            if TAS.GaitOverrideLast ~= want then
                                TAS.GaitOverrideLast = want
                                dbg("OVERRIDE GetAllowedGait -> %s (valeur du jeu %s)", tostring(want), shown)
                            end
                            return want
                        end

                        if TAS.GaitOverrideLast then
                            TAS.GaitOverrideLast = false
                            dbg("OVERRIDE GetAllowedGait relache")
                        end
                    end
                end

                -- PLAY : ResetWalkingGait recoit la vraie valeur de l'axe (0 en
                -- rejeu, 1 en REC) et remet DesiredGait a zero. Le hook tourne
                -- apres la fonction : on reecrit aussitot la valeur du REC.
                if fn == "ResetWalkingGait" and TAS.Mode == "play" and TAS.PlayKeyState then

                    local want = TAS.PlayKeyState.Gait

                    if want ~= nil then
                        pcall(function()
                            local pawn = Context:get()
                            local before = pawn.DesiredGait
                            if before ~= want then
                                pawn.DesiredGait = want
                                if DIAG.desired_last ~= want then
                                    DIAG.desired_last = want
                                    dbg("OVERRIDE DesiredGait -> %s apres ResetWalkingGait (valeur du jeu %s)",
                                        tostring(want), tostring(before))
                                end
                            end
                        end)
                    end
                end

                if TAS.Mode == "idle" then return nil end

                -- Fonctions appelees a chaque frame : on ne logue que les changements
                if fn == "CanSprint" or fn == "GetAllowedGait" or fn == "ResetWalkingGait" then
                    if TAS.GaitHookLast[fn] ~= shown then
                        TAS.GaitHookLast[fn] = shown
                        dbg("KEITH %s -> %s", fn, shown)
                    end
                else
                    dbg("KEITH %s appelee (param %s)", fn, shown)
                end

                return nil
            end)
        end)

        log(string.format("Hook Keith %-16s %s", fn, ok and "installe" or ("absent : " .. tostring(err))))
    end
end

----------------------------------------------------------
-- Jump / StopJumping (moteur) : qui les appelle, et quand ?
-- Fonctions natives : le 2e argument de RegisterHook est un pre-hook.
----------------------------------------------------------

-- REC : valeur recue par les evenements d'axe souris de Keith (hook
-- Blueprint : il tourne apres l'evenement, le parametre est lisible).
local LookHooksInstalled = false

local function install_look_hooks()

    if LookHooksInstalled then return end
    LookHooksInstalled = true

    for channel, fn in pairs(LOOK_EVENTS) do

        local recorded = channel

        local ok, err = pcall(function()
            RegisterHook(KEITH_CLASS .. fn, function(Context, AxisValue)
                if TAS.Mode ~= "rec" then return nil end
                local ok_v, value = pcall(function() return AxisValue:get() end)
                if ok_v and type(value) == "number" then
                    record_value(recorded, value)
                end
                return nil
            end)
        end)

        log(string.format("Hook Keith %s %s", fn, ok and "installe" or ("absent : " .. tostring(err))))
    end
end

local JumpHooksInstalled = false

local function install_jump_hooks()

    if JumpHooksInstalled then return end
    JumpHooksInstalled = true

    for _, name in ipairs({ "Jump", "StopJumping" }) do

        local fn = name

        local ok, err = pcall(function()
            RegisterHook("/Script/Engine.Character:" .. fn, function()
                if TAS.Mode ~= "idle" then
                    dbg("MOTEUR Character:%s appelee", fn)
                    diag_count("Character:" .. fn)
                    DIAG.snap_reason = DIAG.snap_reason or ("Character:" .. fn)
                end
            end)
        end)

        log(string.format("Hook moteur Character:%-12s %s", fn,
            ok and "installe" or ("absent : " .. tostring(err))))
    end
end

----------------------------------------------------------
-- DIAGNOSTIC REC / PLAY
--
-- 10/09 : le rejeu colle a la frame pres pendant 920 frames, puis le
-- timeline JumpGravity est relance en REC depuis 0,300 et en PLAY depuis 0.
-- Keith contient un DoOnce et un Gate (Temp_bool_IsClosed_Variable,
-- Temp_bool_Whether_the_gate_is_currently_open_or_close_Variable) : des
-- variables de l'ubergraph, illisibles comme proprietes. On trace donc
-- tout ce qui est observable, et on compare PLAY a REC automatiquement :
--
--   TRACE        fonctions de Keith appelees (changements d'une frame a l'autre)
--   TRACE ECART  frame ou PLAY n'appelle pas les memes fonctions que REC
--   TL           appels aux fonctions des timelines (Play, Stop...)
--   DEPART       etat complet de Keith au debut de REC et de PLAY
--   SNAP         changements discrets des variables de Keith
--   ECART        premiere divergence PLAY / REC de chaque variable
--   DRIFT        ecart de position / vitesse, frame par frame
--   BILAN        resume a la fin du rejeu
--
-- Les hooks ne font que compter dans DIAG ; le reste tourne dans
-- diag_tick, sur le game thread.
----------------------------------------------------------

local TIMELINE_FUNCS = {
    "Play", "PlayFromStart", "Stop", "Reverse", "ReverseFromEnd",
    "SetPlaybackPosition", "SetNewTime", "SetTimelineLength", "SetPlayRate", "SetLooping"
}

local TRACE_DIFF_MAX = 300

local SCALAR_TYPES = {
    BoolProperty = true, FloatProperty = true, DoubleProperty = true,
    IntProperty = true, Int64Property = true, Int16Property = true, Int8Property = true,
    UInt16Property = true, UInt32Property = true, UInt64Property = true,
    ByteProperty = true, EnumProperty = true, NameProperty = true, StrProperty = true
}

local STRUCT_KINDS = { Vector = "vec", Rotator = "rot", Vector2D = "vec2" }

-- Etat natif du saut et du mouvement : hors de la chaine Blueprint.
local CHAR_FIELDS = {
    "bPressedJump", "bWasJumping", "JumpKeyHoldTime", "JumpForceTimeRemaining",
    "JumpCurrentCount", "JumpMaxCount", "JumpMaxHoldTime", "bIsCrouched"
}

local CMC_FIELDS = {
    "MovementMode", "CustomMovementMode", "GravityScale", "JumpZVelocity",
    "MaxWalkSpeed", "MaxAcceleration", "BrakingDecelerationWalking",
    "BrakingDecelerationFalling", "GroundFriction", "AirControl",
    "FallingLateralFriction", "bOrientRotationToMovement",
    "bUseControllerDesiredRotation", "bNotifyApex", "Velocity"
}

-- Les stubs d'input ne tirent jamais ; GAIT_HOOKS sont deja hookes (et
-- GetAllowedGait surcharge sa valeur de retour : pas de second hook dessus).
local function trace_excluded(name)

    -- Les BndEvt__ (chocs de la capsule et du mesh) finissent aussi par
    -- __DelegateSignature mais sont de vrais evenements : on les garde.
    if name:find("^InpActEvt_")
        or (name:find("__DelegateSignature$") and not name:find("^BndEvt__")) then
        return true
    end

    for _, gait in ipairs(GAIT_HOOKS) do
        if gait == name then return true end
    end

    return false
end

-- Classe de depart, puis ses parents tant qu'ils sont des Blueprints (/Game/).
local function blueprint_chain(cls)

    local chain = {}

    for _ = 1, 8 do

        if not is_alive(cls) then break end

        local ok, full = pcall(function() return cls:GetFullName() end)

        if not ok or not tostring(full):find("/Game/", 1, true) then break end

        chain[#chain + 1] = cls

        local ok_s, super = pcall(function() return cls:GetSuperStruct() end)
        cls = ok_s and super or nil
    end

    return chain
end

local function keith_class()

    local cls = nil

    pcall(function()
        cls = StaticFindObject("/Game/Characters/Keith/Keith_BP.Keith_BP_C")
    end)

    if not is_alive(cls) then
        local pawn = get_player_pawn()
        if pawn then
            pcall(function() cls = pawn:GetClass() end)
        end
    end

    return is_alive(cls) and cls or nil
end

local DiagHooksInstalled = false

local function install_diag_hooks()

    if DiagHooksInstalled or not TAS_CONFIG.diag_trace then return end
    DiagHooksInstalled = true

    -- Timelines : fonctions natives, le 2e argument est un pre-hook.
    local tl_ok = 0

    for _, name in ipairs(TIMELINE_FUNCS) do

        local fn = name

        local ok, err = pcall(function()
            RegisterHook("/Script/Engine.TimelineComponent:" .. fn, function(Context, First)

                if TAS.Mode == "idle" then return end

                local owner, pos, playing = "?", "?", "?"

                pcall(function()
                    local timeline = Context:get()
                    owner = timeline:GetFName():ToString()
                    pos = string.format("%.3f", timeline:GetPlaybackPosition())
                    playing = tostring(timeline:IsPlaying())
                end)

                diag_count("TL:" .. owner .. ":" .. fn)
                DIAG.snap_reason = DIAG.snap_reason or ("TL " .. owner .. ":" .. fn)
                dbg("TL %s:%s (param %s) | avant l'appel : pos %s playing %s",
                    owner, fn, param_text(First), pos, playing)
            end)
        end)

        if ok then
            tl_ok = tl_ok + 1
        else
            log("Hook TimelineComponent:" .. fn .. " absent : " .. tostring(err))
        end
    end

    log(string.format("Hooks timeline : %d / %d", tl_ok, #TIMELINE_FUNCS))

    -- Toutes les fonctions Blueprint de Keith et de ses parents Blueprint.
    local cls = keith_class()

    if not cls then
        log("Trace Keith : classe introuvable, trace des fonctions coupee")
        return
    end

    local paths = {}

    for _, c in ipairs(blueprint_chain(cls)) do
        pcall(function()
            c:ForEachFunction(function(f)
                local ok_f, full = pcall(function() return f:GetFullName() end)
                -- "Function /Game/Characters/Keith/Keith_BP.Keith_BP_C:Nom"
                local path = ok_f and tostring(full):match("^%S+%s+(.+)$")
                local name = path and path:match(":([^:]+)$")
                if name and not trace_excluded(name) then
                    paths[#paths + 1] = { path, name }
                end
            end)
        end)
    end

    local hooked, refused = 0, 0

    for _, entry in ipairs(paths) do

        local path, name = entry[1], entry[2]
        local ok

        if name:find("^ExecuteUbergraph") then

            -- Le point d'entree dit quel evenement du graphe s'execute.
            local labels = {}

            ok = pcall(function()
                RegisterHook(path, function(Context, EntryPoint)
                    if TAS.Mode == "idle" then return nil end
                    local ok_e, entry_point = pcall(function() return EntryPoint:get() end)
                    local key = ok_e and entry_point or -1
                    local label = labels[key]
                    if not label then
                        label = "uber:" .. tostring(key)
                        labels[key] = label
                    end
                    diag_count(label)
                    return nil
                end)
            end)
        elseif name == "ScaleProjectedObject" then

            -- Redimensionnement : ce que la fonction recoit vraiment, a chaque
            -- changement (REC et PLAY), pour comparer.
            ok = pcall(function()
                RegisterHook(path, function(Context, ...)
                    if TAS.Mode == "idle" then return nil end
                    diag_count(name)
                    local parts = {}
                    for _, param in ipairs({ ... }) do
                        local ok_p, value = pcall(function() return param:get() end)
                        parts[#parts + 1] = ok_p and tostring(value) or "?"
                    end
                    local text = table.concat(parts, ", ")
                    if DIAG.scale_last ~= text then
                        DIAG.scale_last = text
                        dbg("SCALE ScaleProjectedObject(%s)", text)
                    end
                    return nil
                end)
            end)
        elseif name:find("^BndEvt__") then

            -- Choc : on trace QUEL objet Keith a touche (capsule ou mesh).
            local part = name:find("CapsuleComponent", 1, true) and "capsule" or "mesh"

            ok = pcall(function()
                RegisterHook(path, function(Context, HitComponent, OtherActor)
                    if TAS.Mode == "idle" then return nil end
                    local other = "?"
                    pcall(function() other = OtherActor:get():GetFName():ToString() end)
                    diag_count("HIT " .. part .. ":" .. other)
                    return nil
                end)
            end)
        else
            ok = pcall(function()
                RegisterHook(path, function()
                    if TAS.Mode ~= "idle" then
                        diag_count(name)
                    end
                    return nil
                end)
            end)
        end

        if ok then hooked = hooked + 1 else refused = refused + 1 end
    end

    log(string.format("Trace Keith : %d fonctions hookees, %d refusees", hooked, refused))
end

-- Camera en PLAY : fonctions natives, le 2e argument est un pre-hook, et
-- :set() y remplace le parametre avant que la fonction ne s'execute.
local CamHooksInstalled = false

local function install_camera_hooks()

    if CamHooksInstalled or not TAS_CONFIG.camera_inject then return end
    CamHooksInstalled = true

    for _, axis in ipairs({ "Yaw", "Pitch" }) do

        local which = axis
        local served = which == "Yaw" and "yaw_frame" or "pitch_frame"

        local ok, err = pcall(function()
            RegisterHook("/Script/Engine.Pawn:AddController" .. which .. "Input", function(Context, Val)

                if TAS.Mode ~= "play" or TAS.ReplayOff.Camera then return end

                local ok_v, original = pcall(function() return Val:get() end)

                -- Premier appel de la frame : l'ecart du REC. Les suivants : 0.
                local want = 0

                if CAM.frame == TAS.Frame and CAM[served] ~= TAS.Frame then
                    CAM[served] = TAS.Frame
                    if which == "Yaw" then
                        want = CAM.dyaw / CAM.yaw_scale
                    else
                        want = CAM.dpitch / CAM.pitch_scale
                    end
                end

                CAM.calls = CAM.calls + 1

                if ok_v and type(original) == "number" and original ~= 0 then
                    CAM.leaks = CAM.leaks + 1
                    if CAM.leaks <= 20 then
                        dbg("SOURIS reelle neutralisee : %s %.4f", which, original)
                    end
                end

                pcall(function() Val:set(want) end)

                if CAM.calls <= 6 then
                    dbg("CAMERA injection %s : valeur du jeu %s -> %.5f", which, tostring(original), want)
                end
            end)
        end)

        log(string.format("Hook Pawn:AddController%sInput %s", which,
            ok and "installe" or ("absent : " .. tostring(err))))
    end
end

-- Pas de temps fixe : chaque frame vaut 1/fixed_fps de temps de jeu.
local function apply_fixed_timestep()

    local fps = TAS_CONFIG.fixed_fps

    if not fps then return end

    local engine = nil

    pcall(function() engine = FindFirstOf("GameEngine") end)

    if not is_alive(engine) then
        log("GameEngine introuvable : pas de temps fixe non applique")
        return
    end

    local function show()
        return string.format("bUseFixedFrameRate %s | FixedFrameRate %s | bSmoothFrameRate %s",
            tostring(read_field(engine, "bUseFixedFrameRate")),
            tostring(read_field(engine, "FixedFrameRate")),
            tostring(read_field(engine, "bSmoothFrameRate")))
    end

    log("Moteur avant : " .. show())

    local ok, err = pcall(function()
        engine.bUseFixedFrameRate = true
        engine.FixedFrameRate = fps
    end)

    log("Moteur apres : " .. show() .. (ok and "" or (" | ERREUR " .. tostring(err))))

    if ok then
        DIAG.engine = engine
        DIAG.fixed_on = true
    end
end

-- Variables de Keith lisibles : scalaires, vecteurs, timelines. Une fois.
local function resolve_props(pawn)

    local list, counts = {}, {}
    local cls = nil

    pcall(function() cls = pawn:GetClass() end)

    for _, c in ipairs(blueprint_chain(cls)) do
        pcall(function()
            c:ForEachProperty(function(p)

                local ok, name, ptype = pcall(function()
                    return p:GetFName():ToString(), p:GetClass():GetFName():ToString()
                end)

                if not ok then return end

                local kind = nil

                if SCALAR_TYPES[ptype] then
                    kind = "s"
                elseif ptype == "StructProperty" then
                    local ok_s, sname = pcall(function() return p:GetStruct():GetFName():ToString() end)
                    kind = ok_s and STRUCT_KINDS[sname] or nil
                elseif ptype == "ObjectProperty" then
                    local ok_c, cname = pcall(function() return p:GetPropertyClass():GetFName():ToString() end)
                    if ok_c and cname == "TimelineComponent" then kind = "tl" end
                end

                if kind then
                    list[#list + 1] = { name = name, kind = kind }
                    counts[ptype] = (counts[ptype] or 0) + 1
                end
            end)
        end)
    end

    local parts = {}

    for ptype, n in pairs(counts) do
        parts[#parts + 1] = ptype .. " " .. n
    end

    table.sort(parts)
    log(string.format("Variables de Keith suivies : %d (%s)", #list, table.concat(parts, ", ")))

    return list
end

local function fmt_num(x)
    if x == math.floor(x) and math.abs(x) < 1e9 then
        return string.format("%d", x)
    end
    return string.format("%.4f", x)
end

-- Valeur d'une variable, toujours sous forme de texte comparable.
local function snap_value(obj, name, kind)

    local ok, v = pcall(function() return obj[name] end)

    if not ok then return "ERR" end

    if kind == "tl" then
        if not is_alive(v) then return "aucun" end
        local out = "?"
        pcall(function()
            out = string.format("pos=%.3f play=%s rev=%s len=%.3f rate=%.2f",
                v:GetPlaybackPosition(), tostring(v:IsPlaying()), tostring(v:IsReversing()),
                v:GetTimelineLength(), v:GetPlayRate())
        end)
        return out
    end

    if kind == "vec" or kind == "rot" or kind == "vec2" then
        local out = "?"
        pcall(function()
            if kind == "rot" then
                out = string.format("%.2f,%.2f,%.2f", v.Pitch, v.Yaw, v.Roll)
            elseif kind == "vec2" then
                out = string.format("%.2f,%.2f", v.X, v.Y)
            else
                out = string.format("%.2f,%.2f,%.2f", v.X, v.Y, v.Z)
            end
        end)
        return out
    end

    local t = type(v)

    if t == "number" then return fmt_num(v) end
    if t == "boolean" or t == "string" then return tostring(v) end

    -- FName, FString
    local ok_s, s = pcall(function() return v:ToString() end)

    if ok_s and type(s) == "string" then return s end

    return "?" .. t
end

local function take_snapshot(pawn)

    if not DIAG.props then
        DIAG.props = resolve_props(pawn)
    end

    local snap = {}

    for _, p in ipairs(DIAG.props) do
        snap[p.name] = snap_value(pawn, p.name, p.kind)
    end

    for _, name in ipairs(CHAR_FIELDS) do
        snap["Char." .. name] = snap_value(pawn, name, "s")
    end

    local cmc = read_field(pawn, "CharacterMovement")

    if is_alive(cmc) then
        for _, name in ipairs(CMC_FIELDS) do
            snap["CMC." .. name] = snap_value(cmc, name, name == "Velocity" and "vec" or "s")
        end
    end

    return snap
end

local function is_float_text(s)
    return s:find("^%-?%d+%.%d+$") ~= nil
end

-- Changements discrets (booleens, entiers, enums, timelines) : les flottants
-- et les vecteurs bougent a chaque frame, ils ne servent qu'a la comparaison.
local function snap_changes(old, new)

    local out = {}

    for name, value in pairs(new) do
        local before = old[name]
        if before ~= nil and before ~= value
            and not is_float_text(value) and not is_float_text(before)
            and not value:find(",", 1, true) then
            out[#out + 1] = name .. " " .. before .. " -> " .. value
        end
    end

    table.sort(out)

    return out
end

local function values_differ(a, b)

    if a == b then return false end

    local x, y = tonumber(a), tonumber(b)

    if x and y then
        return math.abs(x - y) > math.max(1e-3, math.abs(x) * 1e-4)
    end

    return true
end

local function compare_snapshot(f, snap)

    local ref = DIAG.rec_snaps[f]

    if not ref then return end

    local total, fresh = 0, {}

    for name, value in pairs(snap) do
        local expected = ref[name]
        if expected ~= nil and values_differ(expected, value) then
            total = total + 1
            if not DIAG.first_diff[name] then
                DIAG.first_diff[name] = f
                DIAG.first_order[#DIAG.first_order + 1] = name
                fresh[#fresh + 1] = string.format("%s REC=%s PLAY=%s", name, expected, value)
            end
        end
    end

    table.sort(fresh)

    for _, line in ipairs(fresh) do
        dbg("ECART NOUVEAU %s", line)
    end

    if total > 0 then
        dbg("COMPARE : %d variables differentes de REC, dont %d nouvelles", total, #fresh)
    end
end

-- Duree de la frame vue par le jeu. Sondee une fois : si elle ne repond
-- pas, on coupe la mesure plutot que de lever une erreur par frame.
local function world_delta(pawn)

    if DIAG.dt_off then return nil end

    local ok, value = pcall(function()
        local library = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        return library:GetWorldDeltaSeconds(pawn)
    end)

    if ok and type(value) == "number" then return value end

    DIAG.dt_off = true
    log("GetWorldDeltaSeconds ne repond pas : mesure du pas de temps coupee")

    return nil
end

-- Vitesse du jeu, toutes les 5 s, meme au repos (10/09, build -17) :
-- -UseFixedTimeStep -FPS=140 a fait tourner le jeu en accelere. Deux causes
-- possibles, que ces trois nombres departagent :
--   limiteur externe inoperant : fps reels >> 140, dt = 1/140
--   -FPS= non pris en compte  : fps reels ~ 140, dt = 1/30 (defaut moteur)
-- vitesse = fps reels x dt (1.00 = temps reel).
function time_report()

    local now = os.time()

    if not DIAG.t_wall then
        DIAG.t_wall, DIAG.t_frame = now, TAS.Frame
        return
    end

    local secs = os.difftime(now, DIAG.t_wall)

    if secs < 3 then return end

    local frames = TAS.Frame - DIAG.t_frame
    local fps = frames / secs
    local pawn = get_player_pawn()
    local dt = pawn and world_delta(pawn) or nil

    log(string.format("TEMPS : %d frames en %d s = %.0f fps reels | dt du jeu %s | vitesse du jeu x%s | pas fixe moteur %s",
        frames, secs, fps,
        dt and string.format("%.7f s", dt) or "?",
        dt and string.format("%.2f", fps * dt) or "?",
        DIAG.fixed_on and "actif" or "inactif"))

    -- Garde-fou : le pas fixe ne doit jamais accelerer le jeu.
    if DIAG.fixed_on and dt and fps * dt > 1.25 then
        DIAG.fixed_on = false
        if is_alive(DIAG.engine) then
            pcall(function() DIAG.engine.bUseFixedFrameRate = false end)
        end
        log(string.format("VITESSE x%.2f avec le pas fixe du moteur : bUseFixedFrameRate remis a false", fps * dt))
    end

    DIAG.t_wall, DIAG.t_frame = now, TAS.Frame
end

-- Pas de temps : irregulier par rapport a 1/fps, et different du REC.
local function check_dt(f, dt, mode)

    local expected = 1 / (TAS_CONFIG.fixed_fps or 140)

    DIAG.dt_n = DIAG.dt_n + 1
    DIAG.dt_min = math.min(DIAG.dt_min, dt)
    DIAG.dt_max = math.max(DIAG.dt_max, dt)

    if math.abs(dt - expected) > 2e-6 then
        DIAG.dt_irregular = DIAG.dt_irregular + 1
        if DIAG.dt_irregular <= 100 then
            dbg("DT irregulier : %.7f s (attendu %.7f, %+.1f %%)", dt, expected,
                (dt - expected) / expected * 100)
        end
    end

    if mode == "play" and DIAG.has_ref then
        local ref = DIAG.rec_track[f]
        local rec_dt = ref and ref[7]
        if rec_dt and math.abs(rec_dt - dt) > 1e-7 then
            DIAG.dt_diffs = DIAG.dt_diffs + 1
            if DIAG.dt_diffs <= 100 then
                dbg("DT ECART : REC %.7f PLAY %.7f", rec_dt, dt)
            end
        end
    end
end

local function track_sample(pawn)

    local x, y, z = get_player_location(pawn)
    local ok_v, velocity = pcall(function() return pawn:GetVelocity() end)
    local vx, vy, vz = vector_xyz(ok_v and velocity or nil)

    if not x or not vx then return nil end

    return { x, y, z, vx, vy, vz, world_delta(pawn) }
end

-- Paliers de position (unites) ; la vitesse compte a partir de 10x le palier.
-- Build -19 : descendu a 0,001 pour dater le tout debut d'une divergence.
local DRIFT_STEPS = { 0.001, 0.01, 0.1, 1, 10, 100 }

local function drift_check(f, cur)

    local ref = DIAG.rec_track[f]

    if not ref or not cur then return end

    local dp = math.sqrt((cur[1] - ref[1]) ^ 2 + (cur[2] - ref[2]) ^ 2 + (cur[3] - ref[3]) ^ 2)
    local dv = math.sqrt((cur[4] - ref[4]) ^ 2 + (cur[5] - ref[5]) ^ 2 + (cur[6] - ref[6]) ^ 2)

    if f <= 1 then
        dbg("DRIFT depart : dpos %.6f dvel %.6f", dp, dv)
    end

    local level = 0

    for i, step in ipairs(DRIFT_STEPS) do
        if dp > step or dv > step * 10 then level = i end
    end

    if level > DIAG.drift_level then

        if not DIAG.drift_first then
            DIAG.drift_first = f
            DIAG.snap_reason = DIAG.snap_reason or "premier drift"
        end

        dbg("DRIFT niveau %d : dpos %.3f dvel %.3f | REC pos %.1f %.1f %.1f vel %.1f %.1f %.1f | PLAY pos %.1f %.1f %.1f vel %.1f %.1f %.1f",
            level, dp, dv, ref[1], ref[2], ref[3], ref[4], ref[5], ref[6],
            cur[1], cur[2], cur[3], cur[4], cur[5], cur[6])

    elseif level == 0 and DIAG.drift_level > 0 then
        dbg("DRIFT resorbe : dpos %.3f dvel %.3f", dp, dv)
    end

    if level > 0 and f % 30 == 0 then
        dbg("DRIFT suivi : dpos %.2f dvel %.2f", dp, dv)
    end

    DIAG.drift_level = level
end

-- Fonctions appelees depuis le dernier tick, triees ("Nom" ou "Nom x3").
local function trace_signature()

    local names = {}

    for name, count in pairs(DIAG.calls) do
        names[#names + 1] = count > 1 and (name .. " x" .. count) or name
    end

    table.sort(names)
    DIAG.calls = {}

    return names
end

-- Elements de new absents de old, puis de old absents de new.
local function list_diff(old, new)

    local in_old, in_new = {}, {}

    for _, s in ipairs(old) do in_old[s] = true end
    for _, s in ipairs(new) do in_new[s] = true end

    local plus, minus = {}, {}

    for _, s in ipairs(new) do
        if not in_old[s] then plus[#plus + 1] = s end
    end

    for _, s in ipairs(old) do
        if not in_new[s] then minus[#minus + 1] = s end
    end

    return plus, minus
end

local function log_state(label, snap)

    local names = {}

    for name in pairs(snap) do
        names[#names + 1] = name
    end

    table.sort(names)

    local line = {}

    for i, name in ipairs(names) do
        line[#line + 1] = name .. "=" .. snap[name]
        if #line == 6 or i == #names then
            dbg("%s %s", label, table.concat(line, " | "))
            line = {}
        end
    end
end

-- Appele en debut de tick : les fonctions appelees depuis la coupure
-- precedente forment la trace de la frame.
function diag_cut()

    if not TAS_CONFIG.diag_trace then return end

    DIAG.pending_sig = trace_signature()
end

----------------------------------------------------------
-- MINI-SAVESTATE DE KEITH
--
-- 10/09, build -13 : sauter avec JumpCounter = 0 lance le timeline
-- JumpGravity (saut flottant) et passe JumpCounter a 1 ; seule la fin d'une
-- escalade le remet a 0. Le PLAY heritait du 1 laisse par la fin du REC :
-- premier saut sans gravite flottante, drift. Les rotations internes d'ALS
-- (TargetRotation, LastVelocityRotation...) differaient aussi.
--
-- On capture donc au B toutes les variables lisibles de Keith, l'etat natif
-- du saut et du mouvement, et on les reecrit au N. La comparaison DIAG de la
-- frame 0 du PLAY dit ce qui n'a pas pris.
----------------------------------------------------------

-- MovementMode s'ecrit par SetMovementMode, l'accroupi par Crouch() :
-- ecrire le champ directement desynchroniserait le moteur.
local KEITH_NO_RESTORE = {
    ["Char.bIsCrouched"] = true,
    ["CMC.MovementMode"] = true,
    ["CMC.CustomMovementMode"] = true
}

-- Valeur brute, restaurable (nil si non restaurable : FName, FString...).
local function raw_value(obj, name, kind)

    local ok, v = pcall(function() return obj[name] end)

    if not ok or v == nil then return nil end

    if kind == "tl" then
        if not is_alive(v) then return nil end
        local out = nil
        pcall(function()
            out = {
                pos = v:GetPlaybackPosition(), playing = v:IsPlaying(),
                reverse = v:IsReversing(), len = v:GetTimelineLength(), rate = v:GetPlayRate()
            }
        end)
        return out
    end

    if kind == "vec" or kind == "rot" or kind == "vec2" then
        local out = nil
        pcall(function()
            if kind == "rot" then
                out = { Pitch = v.Pitch, Yaw = v.Yaw, Roll = v.Roll }
            elseif kind == "vec2" then
                out = { X = v.X, Y = v.Y }
            else
                out = { X = v.X, Y = v.Y, Z = v.Z }
            end
        end)
        if out then
            for _, value in pairs(out) do
                if type(value) ~= "number" then return nil end
            end
        end
        return out
    end

    local t = type(v)

    if t == "number" or t == "boolean" then return v end

    return nil
end

function capture_keith(pawn)

    if not DIAG.props then
        DIAG.props = resolve_props(pawn)
    end

    local state = {}

    local function put(key, obj, name, kind)
        if KEITH_NO_RESTORE[key] then return end
        local value = raw_value(obj, name, kind)
        if value ~= nil then
            state[key] = { k = kind, v = value }
        end
    end

    for _, p in ipairs(DIAG.props) do
        put(p.name, pawn, p.name, p.kind)
    end

    for _, name in ipairs(CHAR_FIELDS) do
        put("Char." .. name, pawn, name, "s")
    end

    local cmc = read_field(pawn, "CharacterMovement")

    if is_alive(cmc) then
        for _, name in ipairs(CMC_FIELDS) do
            put("CMC." .. name, cmc, name, name == "Velocity" and "vec" or "s")
        end
    end

    local n = 0

    for _ in pairs(state) do n = n + 1 end

    dbg("ETAT KEITH capture : %d valeurs (JumpCounter %s)", n,
        state.JumpCounter and tostring(state.JumpCounter.v) or "-")

    return state
end

local function struct_matches(obj, name, want)

    local ok, s = pcall(function() return obj[name] end)

    if not ok or not s then return false end

    for field, value in pairs(want) do
        local ok_f, got = pcall(function() return s[field] end)
        if not ok_f or type(got) ~= "number" or math.abs(got - value) > 1e-3 then
            return false
        end
    end

    return true
end

-- Affectation d'une table, puis champ par champ en secours ; relue.
local function write_struct(obj, name, want)

    pcall(function() obj[name] = want end)

    if struct_matches(obj, name, want) then return true end

    pcall(function()
        local s = obj[name]
        for field, value in pairs(want) do
            s[field] = value
        end
    end)

    return struct_matches(obj, name, want)
end

local function write_scalar(obj, name, want)

    if not pcall(function() obj[name] = want end) then return false end

    local ok, back = pcall(function() return obj[name] end)

    if not ok then return false end

    if type(want) == "number" then
        return type(back) == "number" and math.abs(back - want) <= math.max(1e-3, math.abs(want) * 1e-5)
    end

    return back == want
end

local function write_timeline(obj, name, want)

    local ok_t, timeline = pcall(function() return obj[name] end)

    if not ok_t or not is_alive(timeline) then return false end

    local ok = pcall(function()
        timeline:Stop()
        timeline:SetPlayRate(want.rate)
        timeline:SetTimelineLength(want.len)
        timeline:SetPlaybackPosition(want.pos, false, false)
        if want.playing then
            if want.reverse then timeline:Reverse() else timeline:Play() end
        end
    end)

    return ok
end

function restore_keith(pawn, state)

    if type(state) ~= "table" then return end

    local cmc = read_field(pawn, "CharacterMovement")
    local done, failed = 0, {}

    for key, entry in pairs(state) do

        if type(entry) == "table" and entry.v ~= nil and not KEITH_NO_RESTORE[key] then

            local obj, name = pawn, key

            if key:sub(1, 5) == "Char." then
                name = key:sub(6)
            elseif key:sub(1, 4) == "CMC." then
                obj, name = cmc, key:sub(5)
            end

            local ok = false

            if is_alive(obj) then
                if entry.k == "tl" then
                    ok = write_timeline(obj, name, entry.v)
                elseif type(entry.v) == "table" then
                    ok = write_struct(obj, name, entry.v)
                else
                    ok = write_scalar(obj, name, entry.v)
                end
            end

            if ok then
                done = done + 1
            else
                failed[#failed + 1] = key
            end
        end
    end

    table.sort(failed)

    dbg("ETAT KEITH restaure : %d valeurs reecrites, %d refusees%s", done, #failed,
        #failed > 0 and (" : " .. table.concat(failed, ", ")) or "")
end

function diag_begin(mode)

    if not TAS_CONFIG.diag_trace then return end

    DIAG.calls = {}
    DIAG.pending_sig = false
    DIAG.desired_last = false
    DIAG.prev_sig = false
    DIAG.snap_prev = false
    DIAG.snap_reason = false
    DIAG.first_diff = {}
    DIAG.first_order = {}
    DIAG.trace_diffs = 0
    DIAG.trace_first = false
    DIAG.drift_level = 0
    DIAG.drift_first = false
    DIAG.last_ms = false
    DIAG.dt_n = 0
    DIAG.dt_min = math.huge
    DIAG.dt_max = 0
    DIAG.dt_irregular = 0
    DIAG.dt_diffs = 0

    if mode == "rec" then
        DIAG.rec_trace = {}
        DIAG.rec_snaps = {}
        DIAG.rec_track = {}
    end

    DIAG.has_ref = mode == "play" and DIAG.rec_snaps[0] ~= nil

    local pawn = get_player_pawn()

    if not pawn then return end

    local snap = take_snapshot(pawn)

    log_state("DEPART " .. mode, snap)

    if mode == "rec" then
        DIAG.rec_snaps[0] = snap
        DIAG.rec_track[0] = track_sample(pawn)
    elseif DIAG.has_ref then
        compare_snapshot(0, snap)
    else
        dbg("DIAG : aucune reference REC en memoire (prise relue du fichier), pas de comparaison")
    end

    DIAG.snap_prev = snap
end

function diag_end(mode)

    if not TAS_CONFIG.diag_trace then return end

    if DIAG.dt_n > 0 then
        dbg("BILAN DT %s : %d frames, min %.7f max %.7f, %d irregulieres, %d differentes du REC",
            mode, DIAG.dt_n, DIAG.dt_min, DIAG.dt_max, DIAG.dt_irregular, DIAG.dt_diffs)
    end

    if mode == "play" then
        dbg("BILAN CAMERA : %d appels servis, %d mouvements de vraie souris neutralises, %d ecarts de rotation",
            CAM.calls, CAM.leaks, CAM.ecarts)
    end

    if mode ~= "play" or not DIAG.has_ref then return end

    table.sort(DIAG.first_order, function(a, b)
        local fa, fb = DIAG.first_diff[a], DIAG.first_diff[b]
        if fa ~= fb then return fa < fb end
        return a < b
    end)

    dbg("BILAN premier drift : frame %s | premiere difference de trace : frame %s | %d variables ont diverge",
        tostring(DIAG.drift_first or "aucun"), tostring(DIAG.trace_first or "aucune"),
        #DIAG.first_order)

    for i = 1, math.min(30, #DIAG.first_order) do
        local name = DIAG.first_order[i]
        dbg("BILAN ecart %2d : frame %d  %s", i, DIAG.first_diff[name], name)
    end
end

function diag_tick()

    if not TAS_CONFIG.diag_trace then return end

    local mode = TAS.Mode
    local f = TAS.Frame - (mode == "rec" and TAS.RecStart or TAS.PlayStart)

    -- 1. Fonctions appelees depuis le dernier tick
    local sig = DIAG.pending_sig or trace_signature()
    DIAG.pending_sig = false

    local plus, minus = list_diff(DIAG.prev_sig or {}, sig)

    if #plus > 0 or #minus > 0 then
        dbg("TRACE %s%s%s",
            #plus > 0 and ("+" .. table.concat(plus, " +")) or "",
            (#plus > 0 and #minus > 0) and " " or "",
            #minus > 0 and ("-" .. table.concat(minus, " -")) or "")
    end

    DIAG.prev_sig = sig

    if mode == "rec" then
        DIAG.rec_trace[f] = sig
    elseif DIAG.has_ref and DIAG.rec_trace[f] then
        local play_only, rec_only = list_diff(DIAG.rec_trace[f], sig)
        if (#play_only > 0 or #rec_only > 0) and DIAG.trace_diffs < TRACE_DIFF_MAX then
            DIAG.trace_diffs = DIAG.trace_diffs + 1
            DIAG.trace_first = DIAG.trace_first or f
            dbg("TRACE ECART REC seul {%s} | PLAY seul {%s}",
                table.concat(rec_only, " "), table.concat(play_only, " "))
        end
    end

    local pawn = get_player_pawn()

    if not pawn then return end

    -- 2. Position et vitesse
    local cur = track_sample(pawn)

    if cur and cur[7] then
        check_dt(f, cur[7], mode)
    end

    if mode == "rec" then
        DIAG.rec_track[f] = cur
    elseif DIAG.has_ref then
        drift_check(f, cur)
    end

    -- 3. Instantane : periodique, ou sur evenement
    local ms = TAS.DbgWatch and TAS.DbgWatch.MovementState

    if ms ~= DIAG.last_ms then
        DIAG.last_ms = ms
        DIAG.snap_reason = DIAG.snap_reason or ("MovementState " .. tostring(ms))
    end

    local reason = DIAG.snap_reason
    DIAG.snap_reason = false

    local interval = TAS_CONFIG.diag_snap_interval or 10

    if not reason and f % interval == 0 then
        reason = "periodique"
    end

    if not reason then return end

    local snap = take_snapshot(pawn)

    if mode == "rec" then
        DIAG.rec_snaps[f] = snap
    end

    local changes = snap_changes(DIAG.snap_prev or snap, snap)

    if #changes > 0 or reason ~= "periodique" then
        dbg("SNAP (%s) : %s", reason,
            #changes > 0 and table.concat(changes, " | ") or "aucun changement discret")
    end

    DIAG.snap_prev = snap

    if mode == "play" and DIAG.has_ref then
        compare_snapshot(f, snap)
    end
end

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
                    dbg("HOOK ACTION %s = %s", name, tostring(value))
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
                    dbg("HOOK IMPULSION %s", name)
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
                    dbg("HOOK ANYKEY index %d", index)
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
    install_axis_override()
    install_gait_hooks()
    install_look_hooks()
    install_jump_hooks()
    install_diag_hooks()
    install_camera_hooks()
    apply_fixed_timestep()
    install_forward_hook()
    install_right_hook()
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

--------------------------------------------------------
-- B / N : ENREGISTRER / REJOUER
--
-- Aucune touche F : beaucoup de petits claviers (60 %, portables) n'ont
-- pas de rangee F, ou l'imposent derriere Fn. Les lettres du mod ont ete
-- choisies apres verification (10/09) :
--   - inutilisees par le jeu (Config/DefaultInput.ini du pak) ;
--   - non liees par un autre mod actif (NoWalls prend K, G, J, H) ;
--   - hors O et T, ecoutes par Shutter_PlayerController ;
--   - a la meme place en AZERTY et en QWERTY (pas de M, pas de chiffres).
--
-- Ces callbacks tournent sur le thread UE4SS. Ils ne font QUE changer la
-- valeur d'une cle existante ; tout le travail est fait par recorder_tick
-- sur le game thread.
--------------------------------------------------------

RegisterKeyBind(
    Key.B,
    function()
        TAS.ModeRequest = "rec"
    end
)

RegisterKeyBind(
    Key.N,
    function()
        TAS.ModeRequest = "play"
    end
)

-- Sonde input : meme principe, le travail est fait sur le game thread.
RegisterKeyBind(
    Key.V,
    function()
        TAS.ModeRequest = "probe"
    end
)

RegisterKeyBind(
    Key.L,
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
-- I : SONDE DES PROPRIETES DU PAWN
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
    "HasRoom", "CanSprint", "CamTargetLocation",
    "SprintHeld", "RunHeld", "AllowedGait", "DesiredGait"
}

RegisterKeyBind(
    Key.I,
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
-- Y : DECOUVERTE DES FONCTIONS D'INPUT
--
-- RegisterKeyBind ne donne pas d'evenement de relachement, donc pas
-- d'etat maintenu. Les evenements d'input du Blueprint, eux, ont des
-- broches Pressed ET Released, et le compilateur genere une fonction
-- par broche avec un index qu'on ne peut pas deviner.
--
-- Ce scan liste les noms exacts pour pouvoir les hooker ensuite.
--------------------------------------------------------

RegisterKeyBind(
    Key.Y,
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
-- U : DEBUG
--------------------------------------------------------

RegisterKeyBind(
    Key.U,
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
log("B = Enregistrer / arreter")
log("N = Rejouer / arreter")
log("V = Sonde input en 3 etapes (touches, saut, sprint)")
log("L = Afficher / masquer le HUD")
log("U = Dump de diagnostic")
log("Y = Scan des fonctions d'input")
log("I = Sonde des proprietes du pawn")

--------------------------------------------------------
-- WAIT FOR HUD
--------------------------------------------------------

install_level_hook()

start_init_loop()


