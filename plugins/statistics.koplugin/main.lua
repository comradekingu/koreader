local InputContainer = require("ui/widget/container/inputcontainer")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Font = require("ui/font")
local TimeVal = require("ui/timeval")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local DEBUG = require("dbg")
local T = require("ffi/util").template
local joinPath = require("ffi/util").joinPath
local _ = require("gettext")
local util = require("util")
local tableutil = require("tableutil")

local statistics_dir = DataStorage:getDataDir() .. "/statistics/"
local history_dir = DataStorage:getHistoryDir()

local ReaderStatistics = InputContainer:new {
    last_time = nil,
    page_min_read_sec = 5,
    page_max_read_sec = 90,
    current_period = 0,
    is_enabled = nil,
    data = {
        title = "",
        authors = "",
        language = "",
        series = "",
        performance_in_pages = {},
        total_time_in_sec = 0,
        highlights = 0,
        notes = 0,
        pages = 0,
    },
}

function ReaderStatistics:init()
    if self.ui.document.is_djvu or self.ui.document.is_pic then
        return
    end

    self.ui.menu:registerToMainMenu(self)
    self.current_period = 0

    local settings = G_reader_settings:readSetting("statistics") or {}
    self.page_min_read_sec = tonumber(settings.min_sec)
    self.page_max_read_sec = tonumber(settings.max_sec)
    self.is_enabled = not (settings.is_enabled == false)
    self.last_time = TimeVal:now()
end

function ReaderStatistics:getBookProperties()
    local props = self.view.document:getProps()
    if props.title == "No document" or props.title == "" then
        -- FIXME: sometimes crengine returns "No document", try one more time
        props = self.view.document:getProps()
    end
    return props
end

function ReaderStatistics:initData(config)
    -- first execution
    if self.is_enabled then
        if not self.data then
            self.data = { performance_in_pages= {} }
            self:inplaceMigration();  -- first time merge data
        end

        local book_properties = self:getBookProperties()
        self.data.title = book_properties.title
        self.data.authors = book_properties.authors
        self.data.language = book_properties.language
        self.data.series = book_properties.series

        self.data.pages = self.view.document:getPageCount()
        return
    end
end

function ReaderStatistics:getStatisticEnabledMenuItem()
    return {
        text = _("Enabled"),
        checked_func = function() return self.is_enabled end,
        callback = function()
            -- if was enabled, have to save data to file
            if self.last_time and self.is_enabled then
                self.ui.doc_settings:saveSetting("stats", self.data)
            end

            self.is_enabled = not self.is_enabled
            -- if was disabled have to get data from file
            if self.is_enabled then
                self:initData(self.ui.doc_settings)
            end
            self:saveSettings()
        end,
    }
end

function ReaderStatistics:updateSettings()
    self.settings_dialog = MultiInputDialog:new {
        title = _("Statistics settings"),
        fields = {
            {
                text = "",
                input_type = "number",
                hint = T(_("Min seconds, default is 5. Current value: %1"),
                           self.page_min_read_sec),
            },
            {
                text = "",
                input_type = "number",
                hint = T(_("Max seconds, default is 90. Current value: %1"),
                           self.page_max_read_sec),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        self.settings_dialog:onClose()
                        UIManager:close(self.settings_dialog)
                    end
                },
                {
                    text = _("Apply"),
                    callback = function()
                        self:saveSettings(MultiInputDialog:getFields())
                        self.settings_dialog:onClose()
                        UIManager:close(self.settings_dialog)
                    end
                },
            },
        },
        width = Screen:getWidth() * 0.95,
        height = Screen:getHeight() * 0.2,
        input_type = "number",
    }
    self.settings_dialog:onShowKeyboard()
    UIManager:show(self.settings_dialog)
end

function ReaderStatistics:addToMainMenu(tab_item_table)
    table.insert(tab_item_table.plugins, {
        text = _("Statistics"),
        sub_item_table = {
            self:getStatisticEnabledMenuItem(),
            {
                text = _("Settings"),
                callback = function() self:updateSettings() end,
            },
            {
                text = _("Current book"),
                callback = function()
                    UIManager:show(KeyValuePage:new{
                        title = _("Statistics"),
                        kv_pairs = self:getCurrentStat(),
                    })
                end
            },
            {
                text = _("All books"),
                callback = function()
                    total_msg, kv_pairs = self:getTotalStats()
                    UIManager:show(KeyValuePage:new{
                        title = total_msg,
                        kv_pairs = kv_pairs,
                    })
                end
            },
        },
    })
end

function ReaderStatistics:getCurrentStat()
    local dates = {}
    for k, v in pairs(self.data.performance_in_pages) do
        dates[os.date("%Y-%m-%d", k)] = ""
    end
    local total_days = util.tableSize(dates)

    local read_pages = util.tableSize(self.data.performance_in_pages)
    local current_page = self.view.state.page -- get current page from the view
    local avg_time_per_page = self.data.total_time_in_sec / read_pages

    return {
        { _("Current period"), util.secondsToClock(self.current_period, false) },
        { _("Time to read"), util.secondsToClock((self.data.pages - current_page) * avg_time_per_page, false) },
        { _("Total time"), util.secondsToClock(self.data.total_time_in_sec, false) },
        { _("Total highlights"), self.data.highlights },
        { _("Total notes"), self.data.notes },
        { _("Total days"), total_days },
        { _("Average time per page"), util.secondsToClock(avg_time_per_page, false) },
        { _("Read pages/Total pages"), read_pages .. "/" .. self.data.pages },
    }
end

function generateReadBooksTable(title, dates)
    local result = {}
    for k, v in tableutil.spairs(dates, function(t, a, b) return t[b].date < t[a].date end) do
        table.insert(result, {
            k,
            T(_("Pages (%1) Time: %2"), v.count, util.secondsToClock(v.read, false))
        })
    end
    return result
end

-- For backward compatibility
function getDatesForBookOldFormat(book)
    local dates = {}

    for k, v in pairs(book.details) do
        local date_text = os.date("%Y-%m-%d", v.time)
        if not dates[date_text] then
            dates[date_text] = {
                date = v.time,
                read = v.read,
                count = 1
            }
        else
            dates[date_text] = {
                read = dates[date_text].read + v.read,
                count = dates[date_text].count + 1,
                date = dates[date_text].date
            }
        end
    end

    return generateReadBooksTable(book.title, dates)
end

function getDatesForBook(book)
    local dates = {}

    for k, v in pairs(book.performance_in_pages) do
        local date_text = os.date("%Y-%m-%d", k)
        if not dates[date_text] then
            dates[date_text] = {
                date = k,
                read = v,
                count = 1
            }
        else
            -- TODO: test this
            local entry = dates[date_text]
            entry.read = entry.read + v
            entry.count = entry.count + 1
        end
    end

    return generateReadBooksTable(book.title, dates)
end

function ReaderStatistics:getTotalStats()
    local total_stats = {
        {
            self.data.title,
            util.secondsToClock(self.data.total_time_in_sec, false),
            callback = function()
                UIManager:show(KeyValuePage:new{
                    title = self.data.title,
                    kv_pairs = getDatesForBook(self.data),
                })
            end,
        }
    }

    -- find stats for all other books in history
    local proceded_titles, total_books_time = self:getStatisticsFromHistory(total_stats)
    total_books_time = total_books_time + self:getOldStatisticsFromDirectory(proceded_titles, total_stats)
    total_books_time = total_books_time + tonumber(self.data.total_time_in_sec)

    return T(_("Total hours read %1"),
             util.secondsToClock(total_books_time, false)),
           total_stats
end

function ReaderStatistics:getStatisticsFromHistory(total_stats)
    local titles = {}
    local total_books_time = 0
    for curr_file in lfs.dir(history_dir) do
        local path = joinPath(history_dir, curr_file)
        if lfs.attributes(path, "mode") == "file" then
            local book_result = self:importFromFile(history_dir, curr_file)
            local book_stats = book_result.stats
            if book_stats and book_stats.total_time_in_sec > 0
                    and book_stats.title ~= self.data.title then
                titles[book_stats.title] = true
                table.insert(total_stats, {
                    book_stats.title,
                    util.secondsToClock(book_stats.total_time_in_sec, false),
                    callback = function()
                        UIManager:show(KeyValuePage:new{
                            title = book_stats.title,
                            kv_pairs = getDatesForBook(book_stats),
                        })
                    end,
                })
                total_books_time = total_books_time + tonumber(book_stats.total_time_in_sec)
            end
        end
    end
    return titles, total_books_time
end

-- For backward compatibility
function ReaderStatistics:getOldStatisticsFromDirectory(exlude_titles, total_stats)
    if lfs.attributes(statistics_dir, "mode") ~= "directory" then
        return 0
    end
    local total_books_time = 0
    for curr_file in lfs.dir(statistics_dir) do
        local path = statistics_dir .. curr_file
        if lfs.attributes(path, "mode") == "file" then
            local book_result = self:importFromFile(statistics_dir, curr_file)
            if book_result and book_result.total_time > 0
                    and book_result.title ~= self.data.title
                    and not exlude_titles[book_result.title] then
                table.insert(total_stats, {
                    book_result.title,
                    util.secondsToClock(book_result.total_time, false),
                    callback = function()
                        UIManager:show(KeyValuePage:new{
                            title = book_result.title,
                            kv_pairs = getDatesForBookOldFormat(book_result),
                        })
                    end,
                })
                total_books_time = total_books_time + tonumber(book_result.total_time)
            end
        end
    end
    return total_books_time
end

function ReaderStatistics:onPageUpdate(pageno)
    if self.is_enabled then
        local curr_time = TimeVal:now()
        local diff_time = curr_time.sec - self.last_time.sec

        -- if last update was more then 10 minutes then current period set to 0
        if (diff_time > 600) then
            self.current_period = 0
        end

        if diff_time >= self.page_min_read_sec and diff_time <= self.page_max_read_sec then
            self.current_period = self.current_period + diff_time
            self.data.total_time_in_sec = self.data.total_time_in_sec + diff_time
            self.data.performance_in_pages[curr_time.sec] = pageno
            -- we cannot save stats each time this is a page update event,
            -- because the self.data may not even be initialized when such a event
            -- comes, which will render a blank stats written into doc settings
            -- and all previous stats are totally wiped out.
            self.ui.doc_settings:saveSetting("stats", self.data)
        end

        self.last_time = curr_time
    end
end

-- For backward compatibility
function ReaderStatistics:inplaceMigration()
    local oldData = self:importFromFile(statistics_dir, self.data.title .. ".stat")
    if oldData then
        for k, v in pairs(oldData.details) do
            self.data.performance_in_pages[v.time] = v.page
        end
    end
end

-- For backward compatibility
function ReaderStatistics:importFromFile(base_path, item)
    item = string.gsub(item, "^%s*(.-)%s*$", "%1") -- trim
    if item ~= ".stat" then
        local statistic_file = joinPath(base_path, item)
        if lfs.attributes(statistic_file, "mode") == "directory" then
            return
        end
        local ok, stored = pcall(dofile, statistic_file)
        if ok then
            return stored
        else
            DEBUG(stored)
        end
    end
end

function ReaderStatistics:onCloseDocument()
    if self.last_time and self.is_enabled then
        self.ui.doc_settings:saveSetting("stats", self.data)
    end
end

function ReaderStatistics:onAddHighlight()
    self.data.highlights = self.data.highlights + 1
end

function ReaderStatistics:onAddNote()
    self.data.notes = self.data.notes + 1
end

-- in case when screensaver starts
function ReaderStatistics:onSaveSettings()
    self:saveSettings()
    self.ui.doc_settings:saveSetting("stats", self.data)
    self.current_period = 0
end

-- screensaver off
function ReaderStatistics:onResume()
    self.current_period = 0
end

function ReaderStatistics:saveSettings(fields)
    if fields then
        self.page_min_read_sec = tonumber(fields[1])
        self.page_max_read_sec = tonumber(fields[2])
    end

    local settings = {
        min_sec = self.page_min_read_sec,
        max_sec = self.page_max_read_sec,
        is_enabled = self.is_enabled,
    }
    G_reader_settings:saveSetting("statistics", settings)
end

function ReaderStatistics:onReadSettings(config)
    self.data = config.data.stats
end

function ReaderStatistics:onReaderReady()
    -- we have correct page count now, do the actual initialization work
    self:initData()
end

return ReaderStatistics
