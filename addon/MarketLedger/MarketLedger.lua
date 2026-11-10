-- Market Ledger
--
-- 1. Price checks in chat. Type ? and an item link (shift-click the item) in guild, officer,
--    party or raid chat. Every player with Market Ledger sees it, they agree among themselves
--    (over hidden addon messages) who has the freshest Auctionator price, and only that one
--    answers. N installs, 1 reply.
-- 2. Data for the Market Ledger website: item names and categories, your character's class,
--    level and professions, and the recipes you know (open each profession window once). Saved to
--    MARKETLEDGER_DB; the uploader sends it with Auctionator's scans.

local ADDON = "MarketLedger"
local PREFIX = "MktLedger"      -- addon message prefix (max 16 chars)
local BID_WINDOW = 1.2          -- seconds to collect bids before deciding who answers
local MAX_LINKS = 3             -- items answered per query

local db, charKey, me
local floor, format = math.floor, string.format

local function Print(msg) print("|cffffd100Market Ledger|r: " .. msg) end

-- ===========================================================================
-- Prices (Auctionator)
-- ===========================================================================

local function Atr() return Auctionator and Auctionator.API and Auctionator.API.v1 end

local function Call(fn, ...)
  if not fn then return nil end
  local ok, v = pcall(fn, ADDON, ...)
  if ok then return v end
end

-- Days since 2020-01-01, the numbering Auctionator and the feed use.
local DAY0 = time({ year = 2020, month = 1, day = 1, hour = 0 })
local function DayNumber() return floor((time() - DAY0) / 86400) end

-- The guild feed for our realm (Data/Feed.lua, written by the Market Ledger app).
local function FeedRealm()
  local f = MARKETLEDGER_FEED
  if type(f) ~= "table" or type(f.realms) ~= "table" then return nil end
  local realm = Auctionator and Auctionator.State and Auctionator.State.CurrentRealm
  if realm and f.realms[realm] then return f.realms[realm] end
  for _, r in pairs(f.realms) do return r end
end

-- From the feed: price, days old, 7-day average, listed, how many uploaders agreed.
local function FeedInfo(link)
  local realm = FeedRealm()
  if not realm then return nil end
  local key
  if Auctionator and Auctionator.Utilities then
    local ok, k = pcall(Auctionator.Utilities.BasicDBKeyFromLink, link)
    if ok then key = k end
  end
  local e = (key and realm[key]) or realm[link:match("|Hitem:(%d+)") or ""]
  if type(e) ~= "table" or not e[1] then return nil end
  return e[1], e[4] and (DayNumber() - e[4]) or nil, e[2], e[3], e[5]
end

-- From this player's own Auctionator scans: price, days old, 7-day average, listed.
local function LocalInfo(link)
  local api = Atr()
  if not api then return nil end
  local price = Call(api.GetAuctionPriceByItemLink, link)
  local age = Call(api.GetAuctionAgeByItemLink, link)
  local mean, avail
  local dbm = Auctionator.Database
  local okKey, key = pcall(Auctionator.Utilities.BasicDBKeyFromLink, link)
  if okKey and key and dbm then
    -- Newest day first. (Not dbm:GetMeanPrice: it skips days that had a single scan.)
    local ok, hist = pcall(dbm.GetPriceHistory, dbm, key)
    if ok and type(hist) == "table" and hist[1] then
      avail = hist[1].available
      local newest, total, n = tonumber(hist[1].rawDay), 0, 0
      for _, h in ipairs(hist) do
        local day = tonumber(h.rawDay)
        if newest and day and day > newest - 7 and h.minSeen then total, n = total + h.minSeen, n + 1 end
      end
      if n > 0 then mean = total / n end
    end
  end
  return price, age, mean, avail
end

-- The fresher of the guild feed and our own scans (the feed wins ties: it's everyone's consensus).
-- Returns price, age, mean, listed, and a note on where it came from.
local function PriceInfo(link)
  local fp, fage, fmean, favail, fn = FeedInfo(link)
  local lp, lage, lmean, lavail = LocalInfo(link)
  if fp and (not lp or (fage or 99) <= (lage or 99)) then
    return fp, fage, fmean, favail, (fn and fn > 1) and format("%d scanners", fn) or "guild data"
  end
  return lp, lage, lmean, lavail, lp and "my scan" or nil
end

local function Money(c)
  if not c then return "?" end
  c = floor(c + 0.5)
  local g, s, cc = floor(c / 10000), floor(c / 100) % 100, c % 100
  if g >= 100 then return format("%dg", g) end
  if g > 0 then return format("%dg %ds", g, s) end
  if s > 0 then return format("%ds %dc", s, cc) end
  return format("%dc", cc)
end

local function AgeText(age)
  if age == nil then return "no recent scan" end
  if age == 0 then return "scanned today" end
  if age == 1 then return "scanned yesterday" end
  return format("scanned %dd ago", age)
end

-- ===========================================================================
-- Price checks: ?[item link] in chat, one answer per query
-- ===========================================================================

-- Chat event -> the chat type to answer in, and the addon channel to coordinate on.
local CHANNELS = {
  CHAT_MSG_GUILD = { "GUILD", "GUILD" },
  CHAT_MSG_OFFICER = { "OFFICER", "OFFICER" },
  CHAT_MSG_PARTY = { "PARTY", "PARTY" },
  CHAT_MSG_PARTY_LEADER = { "PARTY", "PARTY" },
  CHAT_MSG_RAID = { "RAID", "RAID" },
  CHAT_MSG_RAID_LEADER = { "RAID", "RAID" },
  CHAT_MSG_INSTANCE_CHAT = { "INSTANCE_CHAT", "INSTANCE_CHAT" },
  CHAT_MSG_INSTANCE_CHAT_LEADER = { "INSTANCE_CHAT", "INSTANCE_CHAT" },
}

local pending = {}  -- [qid] = { bids = {name = score}, chatType, links, answered }
local early = {}    -- bids that arrived before we saw the chat line: [qid] = {name = score}
local seen = {}     -- [qid] = time, so a repeated line within 15s isn't answered twice

-- Forever names have two parts: UnitName("player") returns the first name and the surname, which
-- the game joins with its own separator. Chat and addon messages carry that joined form.
local function PlayerName(sep)
  local first, surname = UnitName("player")
  if surname and surname ~= "" then
    local joiner = sep or (Constants and Constants.CharacterNameSeparatorConsts
      and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR) or "-"
    return first .. joiner .. surname
  end
  return first
end

-- Senders are compared exactly as the server wrote them. Our own name, as others see it, is learned
-- from the echo of a hello we send (see OnAddonMessage); until then this guess stands in.
local function FullName(name)
  if not name or name == "" then return nil end
  return name
end
local helloNonce

-- A short id every client computes the same way from the same chat line.
local function QueryId(sender, text)
  local h = 5381
  local s = sender .. "\1" .. text
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return format("%08x", h)
end

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

local function Send(chatType, text)
  pcall(SendChatMessage, text, chatType)
end

local function Answer(p)
  for _, link in ipairs(p.links) do
    local price, age, mean, avail, from = PriceInfo(link)
    local parts = { link .. ":" }
    if price then
      parts[#parts + 1] = Money(price)
      if mean and mean > 0 then parts[#parts + 1] = "· 7-day avg " .. Money(mean) end
      if avail then parts[#parts + 1] = format("· %d listed", avail) end
      parts[#parts + 1] = "· " .. AgeText(age)
      if from == "my scan" or (from and from:find("scanners")) then parts[#parts + 1] = "(" .. from .. ")" end
    else
      parts[#parts + 1] = "no price in anyone's scans yet"
    end
    Send(p.chatType, "[Ledger] " .. table.concat(parts, " "))
  end
end

-- Lower score wins: days since the freshest scan among the asked-for items (99 = no price at all).
local function MyScore(links)
  local best = 99
  for _, link in ipairs(links) do
    local price, age = PriceInfo(link)
    if price then best = math.min(best, age or 50) end
  end
  return best
end

local function Decide(qid)
  local p = pending[qid]
  pending[qid] = nil
  if not p or p.answered then return end
  local winner, winScore
  for name, score in pairs(p.bids) do
    if not winner or score < winScore or (score == winScore and name < winner) then
      winner, winScore = name, score
    end
  end
  if winner == me then
    C_ChatInfo.SendAddonMessage(PREFIX, "A:" .. qid, p.comm)
    Answer(p)
  end
end

local function OnChat(event, text, sender)
  local ch = CHANNELS[event]
  if not ch or IsSecret(text) or IsSecret(sender) then return end
  if not text:match("^%s*%?%s*|c") then return end
  local links = {}
  for link in text:gmatch("|c[^|]*|Hitem:.-|h|r") do
    links[#links + 1] = link
    if #links >= MAX_LINKS then break end
  end
  if #links == 0 then return end

  local qid = QueryId(FullName(sender) or "", text)
  local now = GetTime()
  if seen[qid] and now - seen[qid] < 15 then return end
  seen[qid] = now

  local p = { bids = early[qid] or {}, chatType = ch[1], comm = ch[2], links = links }
  early[qid] = nil
  pending[qid] = p
  local score = MyScore(links)
  p.bids[me] = score
  C_ChatInfo.SendAddonMessage(PREFIX, format("B:%s:%d", qid, score), p.comm)
  C_Timer.After(BID_WINDOW, function() Decide(qid) end)
end

local function OnAddonMessage(prefix, msg, _, sender)
  if prefix ~= PREFIX or IsSecret(msg) then return end
  sender = FullName(sender)
  if not sender then return end
  local kind, qid, score = msg:match("^(%a):(%x+):?(%d*)$")
  if kind == "H" then
    if qid == helloNonce then me = sender end -- our own hello came back: that's how others see our name
    return
  end
  if sender == me then return end
  if kind == "B" then
    score = tonumber(score) or 99
    if pending[qid] then
      pending[qid].bids[sender] = score
    else
      early[qid] = early[qid] or {}
      early[qid][sender] = score
      C_Timer.After(10, function() early[qid] = nil end)
    end
  elseif kind == "A" and pending[qid] then
    pending[qid].answered = true
  end
end

-- ===========================================================================
-- Website data: recipes, character, item names
-- ===========================================================================

local function IsRegularMat(slot)
  local RT, ST = Enum.CraftingReagentType, Enum.TradeskillSlotDataType
  if slot.reagentType == RT.Modifying and slot.required then return true end
  if slot.reagentType ~= RT.Basic then return false end
  return slot.dataSlotType == ST.Reagent or slot.dataSlotType == ST.ModifiedReagent
end

local function ScanOpenProfession()
  local T = C_TradeSkillUI
  if not T or not T.IsTradeSkillReady() then return end
  if T.IsTradeSkillLinked() or T.IsTradeSkillGuild() then return end
  if T.IsNPCCrafting and T.IsNPCCrafting() then return end
  local prof = T.GetBaseProfessionInfo()
  local profName = prof and (prof.professionName or prof.parentProfessionName)
  if not profName or profName == "" then return end

  local recipes = {}
  for _, recipeID in ipairs(T.GetAllRecipeIDs()) do
    local info = T.GetRecipeInfo(recipeID)
    if info and info.learned and not info.isRecraft and not info.isSalvageRecipe then
      local s = T.GetRecipeSchematic(recipeID, false)
      if s and s.outputItemID then
        local mats, usable = {}, true
        for _, slot in ipairs(s.reagentSlotSchematics or {}) do
          if IsRegularMat(slot) then
            local r = slot.reagents and slot.reagents[1]
            if r and r.itemID then mats[#mats + 1] = { itemID = r.itemID, qty = slot.quantityRequired } else usable = false end
          end
        end
        if usable then
          recipes[#recipes + 1] = { id = recipeID, name = info.name, out = s.outputItemID,
            qmin = s.quantityMin or 1, qmax = s.quantityMax or 1, mats = mats }
        end
      end
    end
  end
  if #recipes == 0 then return end
  db.chars[charKey] = db.chars[charKey] or {}
  db.chars[charKey][profName] = { recipes = recipes, scanned = time() }
end

local scanPending = false
local function QueueScan()
  if scanPending then return end
  scanPending = true
  C_Timer.After(0.5, function() scanPending = false; ScanOpenProfession() end)
end

local GetItemInfoCompat = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function SaveCharacter()
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")
  local profs = {}
  if GetProfessions and GetProfessionInfo then
    local list = { GetProfessions() }
    for i = 1, select("#", GetProfessions()) do
      local idx = list[i]
      if idx then
        local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(idx)
        if name then profs[#profs + 1] = { name = name, rank = rank, max = maxRank, id = skillLine } end
      end
    end
  end
  if #profs == 0 and GetNumSkillLines then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
      if name and not isHeader and maxRank and maxRank > 1 then profs[#profs + 1] = { name = name, rank = rank, max = maxRank } end
    end
  end
  db.characters[charKey] = { name = PlayerName(" "), realm = GetRealmName(), class = class, race = race, level = UnitLevel("player"),
    faction = UnitFactionGroup("player"), professions = profs, updated = time() }
end

local itemQueue, queued, pumping = {}, {}, false

local function SaveItem(id)
  local name, _, quality, ilvl, _, _, _, _, _, _, sellPrice, classID, subclassID = GetItemInfoCompat(id)
  if name then db.items[id] = { n = name, q = quality, l = ilvl, v = sellPrice, c = classID, s = subclassID } end
end

local function QueueItem(id)
  if type(id) ~= "number" or queued[id] or db.items[id] then return end
  queued[id] = true
  itemQueue[#itemQueue + 1] = id
end

local function PumpItems()
  for _ = 1, 40 do
    local id = table.remove(itemQueue)
    if not id then break end
    if GetItemInfoCompat(id) then
      SaveItem(id)
    else
      local item = Item:CreateFromItemID(id)
      if not item:IsItemEmpty() then item:ContinueOnItemLoad(function() SaveItem(id) end) end
    end
  end
  if #itemQueue > 0 then C_Timer.After(0.25, PumpItems) else pumping = false end
end

local function CollectItemInfo()
  local atr = Auctionator and Auctionator.Database and Auctionator.Database.db
  if type(atr) == "table" then
    for key in pairs(atr) do
      if type(key) == "string" then QueueItem(tonumber(key) or tonumber(key:match("^g:(%d+)"))) end
    end
  end
  for _, profs in pairs(db.chars) do
    for _, data in pairs(profs) do
      for _, r in ipairs(data.recipes or {}) do
        QueueItem(r.out)
        for _, m in ipairs(r.mats) do QueueItem(m.itemID) end
      end
    end
  end
  if not pumping and #itemQueue > 0 then pumping = true; PumpItems() end
end

-- ===========================================================================
-- The guide: a window that walks you through setup, opened only from the
-- minimap orb or /ledger (it never opens by itself).
-- ===========================================================================

local SITE = "https://wow-market.apps.inevitable.fyi"
local guide
local GREEN, YELLOW, GREY = "|cff40ff40", "|cffffd100", "|cff9d9d9d"

local function Check(ok, text, hint)
  local mark = ok and "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t " or "|TInterface\\RaidFrame\\ReadyCheck-Waiting:14|t "
  return mark .. text .. ((not ok and hint) and ("\n     " .. GREY .. hint .. "|r") or "")
end

local function Since(t)
  if not t then return nil end
  local s = time() - t
  if s < 3600 then return format("%d minutes ago", floor(s / 60)) end
  if s < 86400 then return format("%d hours ago", floor(s / 3600)) end
  return format("%d days ago", floor(s / 86400))
end

local function StatusText()
  local lines = {}
  lines[#lines + 1] = Check(Atr() ~= nil, "Auctionator is installed",
    "Install Auctionator (CurseForge). Market Ledger's prices come from its scans.")

  local f = MARKETLEDGER_FEED
  local realm = FeedRealm()
  local n = 0
  if realm then for _ in pairs(realm) do n = n + 1 end end
  if type(f) == "table" and f.generated and n > 0 then
    lines[#lines + 1] = Check(true, format("Guild prices loaded: %d items, from %s (%s)", n, date("%b %d %H:%M", f.generated), Since(f.generated)))
    if time() - f.generated > 86400 then
      lines[#lines + 1] = "     " .. GREY .. "Over a day old: is the Market Ledger app running? Prices load when you log in or /reload.|r"
    end
  else
    lines[#lines + 1] = Check(false, "Guild prices",
      "Install the Market Ledger app (see the Website page) to get everyone's scans. Until then, price checks use only your own scans.")
  end

  lines[#lines + 1] = Check(db.lastAuction ~= nil,
    db.lastAuction and format("Last auction house visit: %s", Since(db.lastAuction)) or "Scan the auction house",
    "Visit the auction house and run Auctionator's Full Scan (see the Scanning page).")

  local profs = db.chars[charKey]
  local np, nr = 0, 0
  if profs then for _, d in pairs(profs) do np = np + 1; nr = nr + #(d.recipes or {}) end end
  lines[#lines + 1] = Check(np > 0, np > 0 and format("Recipes saved: %d from %d profession%s", nr, np, np == 1 and "" or "s") or "Recipes",
    "Open each of your profession windows once, so the website knows what you can craft.")

  local items = 0
  for _ in pairs(db.items) do items = items + 1 end
  lines[#lines + 1] = Check(items > 0, format("Item names saved: %d", items), "These fill in a few seconds after login.")
  return table.concat(lines, "\n\n")
end

local PAGES = {
  { title = "Status", text = StatusText },
  { title = "Scanning", text = function() return table.concat({
    YELLOW .. "Prices come from auction house scans.|r Every scan anyone in the guild shares makes the prices better for everyone.",
    "1. Go to an auction house and open it.",
    "2. Click Auctionator's tab, then " .. YELLOW .. "Full Scan|r. It takes a few minutes; you can keep the window open or come back.",
    "3. The Market Ledger app shares the scan once WoW saves it: when you log out or type " .. YELLOW .. "/reload|r.",
    "Scan whenever you're at the auction house anyway. Once a day is plenty.",
    GREY .. "Check it arrived: open the website's Uploads page, or click the app's icon and choose \"See my uploads\".|r",
  }, "\n\n") end },
  { title = "Price checks", text = function() return table.concat({
    YELLOW .. "Ask the guild:|r type " .. YELLOW .. "?|r and shift-click an item in guild, officer, party or raid chat. Up to three items at once.",
    "One player with Market Ledger answers, so the channel gets a single reply however many have it installed:",
    GREY .. "[Ledger] [Copper Ore]: 61c · 7-day avg 65c · 9238 listed · scanned today (4 scanners)|r",
    "That's the cheapest listing on the latest scan, the average over a week, how many were listed, how fresh the data is, and how many people's scans agree.",
    YELLOW .. "Just for you:|r type " .. YELLOW .. "/ledger|r and shift-click an item.",
    "Guild prices refresh when you log in or /reload.",
  }, "\n\n") end },
  { title = "Where prices come from", text = function() return table.concat({
    YELLOW .. "How a scan becomes everyone's price:|r",
    "1. You run Auctionator's Full Scan. WoW saves it to your computer when you log out or /reload.",
    "2. The Market Ledger app notices the new file and sends it to the Market Ledger server.",
    "3. The server keeps each person's scans separately and, for every item and day, takes the " .. YELLOW .. "middle value|r (median) of everyone who scanned it. One odd or bad scan can't drag a price; an uploader sending junk can be banned.",
    "4. Every 10 minutes the app downloads the merged prices into this addon.",
    "5. WoW reads them when you log in or /reload. If your own scan of an item is newer than the guild's, your scan is used.",
    GREY .. "The addon itself never touches the internet: WoW doesn't allow it. The app does the sending and fetching.|r",
  }, "\n\n") end },
  { title = "Who answers", text = function() return table.concat({
    YELLOW .. "Many players have the addon; only one replies.|r",
    "1. Someone types ? and an item. Everyone with Market Ledger in that channel sees it.",
    "2. Each of them sends a hidden addon message (players never see these): a " .. YELLOW .. "bid|r saying how many days old their price for that item is.",
    "3. Everyone waits about a second, collecting the bids, then applies the same rule: the " .. YELLOW .. "freshest price wins|r, and a tie goes to the name first in alphabetical order.",
    "4. Because everyone sees the same bids and uses the same rule, they all agree on one winner. The winner posts the reply and sends a hidden \"answered\" note so anyone who was late stays quiet.",
    GREY .. "With the app, everyone has the same guild prices, so most ties are settled by name. Without it, whoever scanned most recently answers.|r",
  }, "\n\n") end },
  { title = "Website", text = function() return table.concat({
    "Price history, market trends, the best deals, and what each of your characters can craft or gather for profit:",
    "\n\n\n", -- room for the address box
    "The Market Ledger app (Mac and Windows) is on the site's \"Get Market Ledger\" page. It installs and updates this addon, shares your scans, and brings back everyone's prices.",
    GREY .. "Select the address, copy it with Ctrl-C (Cmd-C on a Mac) and paste it into your browser.|r",
  }, "\n\n") end },
}

local function ShowPage(i)
  guide.page = i
  for j, b in ipairs(guide.tabs) do
    if j == i then b:LockHighlight() else b:UnlockHighlight() end
  end
  guide.body:SetText(PAGES[i].text())
  guide.url:SetShown(PAGES[i].title == "Website")
end

local function CreateGuide()
  local g = CreateFrame("Frame", "MarketLedgerGuide", UIParent, "BasicFrameTemplateWithInset")
  g:SetSize(600, 440)
  g:SetPoint("CENTER")
  g:SetMovable(true)
  g:EnableMouse(true)
  g:SetClampedToScreen(true)
  g:RegisterForDrag("LeftButton")
  g:SetScript("OnDragStart", g.StartMoving)
  g:SetScript("OnDragStop", g.StopMovingOrSizing)
  g:SetFrameStrata("HIGH")
  tinsert(UISpecialFrames, "MarketLedgerGuide") -- Escape closes it

  local title = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -5)
  title:SetText("Market Ledger")

  g.tabs = {}
  for i, page in ipairs(PAGES) do
    local b = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    b:SetSize(150, 24)
    b:SetPoint("TOPLEFT", 14, -34 - (i - 1) * 28)
    b:SetText(page.title)
    b:SetScript("OnClick", function() ShowPage(i) end)
    g.tabs[i] = b
  end

  g.body = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  g.body:SetPoint("TOPLEFT", 180, -38)
  g.body:SetPoint("BOTTOMRIGHT", -18, 18)
  g.body:SetJustifyH("LEFT")
  g.body:SetJustifyV("TOP")
  g.body:SetSpacing(2)

  g.url = CreateFrame("EditBox", nil, g, "InputBoxTemplate")
  g.url:SetSize(330, 24)
  g.url:SetPoint("TOPLEFT", 188, -86)
  g.url:SetAutoFocus(false)
  g.url:SetText(SITE)
  g.url:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  g.url:SetScript("OnTextChanged", function(self, user) if user then self:SetText(SITE); self:HighlightText() end end)
  g.url:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  g:SetScript("OnShow", function() ShowPage(g.page or 1) end)
  g:Hide()
  return g
end

local function ToggleGuide()
  guide = guide or CreateGuide()
  guide:SetShown(not guide:IsShown())
end

-- The minimap orb: drag it around the minimap's edge; click to open the guide.
local orb
local function PlaceOrb()
  local a = math.rad(db.minimap.angle or 200)
  local r = (Minimap:GetWidth() / 2) + 10
  orb:ClearAllPoints()
  orb:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function CreateOrb()
  orb = CreateFrame("Button", "MarketLedgerMinimapButton", Minimap)
  orb:SetSize(31, 31)
  orb:SetFrameStrata("MEDIUM")
  orb:SetFrameLevel(8)
  orb:RegisterForClicks("AnyUp")
  orb:RegisterForDrag("LeftButton")
  orb:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = orb:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = orb:CreateTexture(nil, "ARTWORK")
  icon:SetSize(18, 18)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
  icon:SetPoint("TOPLEFT", 7, -6)
  orb.icon = icon
  local border = orb:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  orb:SetScript("OnClick", ToggleGuide)
  orb:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      PlaceOrb()
    end)
  end)
  orb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  orb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Market Ledger")
    local f = MARKETLEDGER_FEED
    if type(f) == "table" and f.generated then
      GameTooltip:AddLine("Guild prices from " .. date("%b %d %H:%M", f.generated), 1, 1, 1)
    else
      GameTooltip:AddLine("No guild prices yet", 1, 0.82, 0)
    end
    GameTooltip:AddLine("Click: open the guide", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Drag: move around the minimap", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  orb:SetScript("OnLeave", GameTooltip_Hide)
  PlaceOrb()
  orb:SetShown(not db.minimap.hide)
end

-- ===========================================================================
-- Events
-- ===========================================================================

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    MARKETLEDGER_DB = MARKETLEDGER_DB or {}
    db = MARKETLEDGER_DB
    db.chars, db.characters, db.items = db.chars or {}, db.characters or {}, db.items or {}
    db.minimap = db.minimap or {}
    charKey = PlayerName() .. " @ " .. GetRealmName()
    self:UnregisterEvent("ADDON_LOADED")
    for _, e in ipairs({ "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
      "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP", "AUCTION_HOUSE_CLOSED", "CHAT_MSG_ADDON" }) do self:RegisterEvent(e) end
    for e in pairs(CHANNELS) do self:RegisterEvent(e) end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  elseif event == "PLAYER_LOGIN" then
    me = PlayerName()
    if IsInGuild() then
      helloNonce = format("%08x", math.random(0, 0x7fffffff))
      C_Timer.After(5, function() C_ChatInfo.SendAddonMessage(PREFIX, "H:" .. helloNonce, "GUILD") end)
    end
    if not Atr() then Print("Auctionator isn't loaded, so price checks can't answer. Install Auctionator.") end
    C_Timer.After(10, function() SaveCharacter(); CollectItemInfo() end)
    CreateOrb()
  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)
  elseif CHANNELS[event] then
    if me then OnChat(event, ...) end
  elseif event == "SKILL_LINES_CHANGED" or event == "PLAYER_LEVEL_UP" then
    C_Timer.After(1, SaveCharacter)
  elseif event == "AUCTION_HOUSE_CLOSED" then
    db.lastAuction = time()
    CollectItemInfo()
  else
    QueueScan()
  end
end)

SLASH_MARKETLEDGER1 = "/ledger"
SlashCmdList.MARKETLEDGER = function(msg)
  local link = msg and msg:match("|c[^|]*|Hitem:.-|h|r")
  if msg and strtrim(msg):lower() == "minimap" then
    db.minimap.hide = not db.minimap.hide
    if orb then orb:SetShown(not db.minimap.hide) end
    Print(db.minimap.hide and "Minimap button hidden. /ledger minimap brings it back." or "Minimap button shown.")
    return
  end
  if not link and (not msg or strtrim(msg) == "") then
    ToggleGuide()
    return
  end
  if link then
    local price, age, mean, avail, from = PriceInfo(link)
    Print(format("%s: %s, 7-day avg %s, %s listed, %s (%s)", link, Money(price), Money(mean), tostring(avail or "?"), AgeText(age), from or "no data"))
  else
    local f = MARKETLEDGER_FEED
    if type(f) == "table" and f.generated then
      Print(format("Guild prices from %s. The Market Ledger app refreshes them; /reload to load the newest.", date("%b %d %H:%M", f.generated)))
    else
      Print("No guild prices yet: install the Market Ledger app to get everyone's scans. Using your own Auctionator scans.")
    end
    Print("Type ? and shift-click an item in guild chat for a price check, or /ledger [item] to check it yourself.")
  end
end
