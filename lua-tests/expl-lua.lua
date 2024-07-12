----------------------
--- Initialization ---
----------------------

-- Save some locals for a slight speed boost.
local append              = table.append
local concatenate         = table.concat
local create_token        = token.create
local direct_get_data     = node.direct.getdata
local direct_set_data     = node.direct.setdata
local direct_set_field    = node.direct.setfield
local getmetatable        = getmetatable
local insert              = table.insert
local ipairs              = ipairs
local lua_functions_table = lua.get_functions_table()
local merge_array         = table.imerged
local merge_hash          = table.merged
local new_lua_function    = luatexbase.new_luafunction
local new_token           = token.new
local next                = next
local pairs               = pairs
local run_tokens          = tex.runtoks
local scan_argument       = token.scan_argument
local scan_csname         = token.scan_csname
local scan_expanded       = token.scan_token
local scan_int            = token.scan_int
local scan_string         = token.scan_string
local scan_token          = token.get_next
local scan_toks           = token.scan_toks
local setmetatable        = setmetatable
local sorted_pairs        = table.sortedpairs
local sprint              = tex.sprint
local string_char         = string.char
local tex_get             = tex.get
local token               = token
local token_get_csname    = token.get_csname
local token_get_mode      = token.get_mode
local token_set_char      = token.set_char
local token_set_lua       = token.set_lua
local tonumber            = tonumber
local unpack              = table.unpack
local write_token         = token.put_next


------------------------
--- Helper Functions ---
------------------------
-- This section is mainly copied from:
--     https://github.com/gucci-on-fleek/luatools/blob/master/source/luatools.lua

--- @enum (key) _arguments_type
local argument_types = {
    argument = { variant = "n", scanner = scan_argument, },
    csname   = { variant = "N", scanner = scan_csname,   },
    int      = { variant = "w", scanner = scan_int,      },
    string   = { variant = "n", scanner = scan_string,   },
    token    = { variant = "N", scanner = scan_token,    },
    toks     = { variant = "n", scanner = scan_toks,     },
}

--- The parameters for defining a new macro.
--- @class (exact)  _macro_define
---
--- The Lua function to run when the macro is called.
--- @field func  fun(...): nil
---
--- The module in which to place the macro.
--- @field module  string
---
--- The name of the macro.
--- @field name  string
---
--- A list of the arguments that the macro takes (Default: `{}`).
--- @field arguments?  _arguments_type[]
---
--- The scope of the macro: `local` or `global` (Default: `local`).
--- @field scope?  "local" | "global"
---
--- The visibility of the macro: `public` or `private` (Default: `private`).
--- @field visibility? "public" | "private"
---
--- Whether the macro is `protected` (Default: `false`).
--- @field ["protected"]?  boolean
---
--- Whether to ignore the scanners, which is more annoying to implement, but
--- faster. (Default: `false`).
--- @field no_scan?  boolean

--- Defines a new macro.
---
--- The parameters for the new macro.
--- @param  params _macro_define
local function define_macro(params)
    -- Setup the default parameters
    local arguments = params.arguments or {}
    local func      = params.func

    -- Get the macro's name
    local name_components = { params.module, "_", params.name, ":" }
    if params.visibility == "private" then
        insert(name_components, 1, "__")
    end

    for _, argument in ipairs(arguments) do
        insert(name_components, argument_types[argument].variant)
    end

    local name = concatenate(name_components)

    -- Generate the scanning function
    local scanning_func
    if #arguments == 0 or params.no_scan then
        -- No arguments, so we can just run the function directly
        scanning_func = func
    else
        -- Before we can run the given function, we need to scan for the
        -- requested arguments in \TeX{}, then pass them to the function.
        local scanners = {}
        for _, argument in ipairs(arguments) do
            insert(scanners, argument_types[argument].scanner)
        end

        -- An intermediate function that properly “scans” for its arguments
        -- in the \TeX{} side.
        scanning_func = function()
            local values = {}
            for _, scanner in ipairs(scanners) do
                insert(values, scanner())
            end

            func(unpack(values))
        end
    end

    -- Handle scope and protection
    local extra_params = {}
    if params.scope == "global" then
        insert(extra_params, "global")
    end
    if params.protected then
        insert(extra_params, "protected")
    end

    local index = new_lua_function(name)
    lua_functions_table[index] = scanning_func
    token_set_lua(name, index, unpack(extra_params))
end


--- @class _memoized<K, V>: { [K]: V } A memoized table.
--- @operator call(any): any           - -

--- Memoizes a function call/table index.
---
--- @generic K, V              -
--- @param  func fun(key:K):V? The function to memoize
--- @return _memoized<K, V> -  The “function”
local function memoized(func)
    return setmetatable({}, { __index = function(cache, key)
        local ret = func(key)
        cache[key] = ret
        return ret
    end,  __call = function(self, arg)
        return self[arg]
    end })
end

local codepoint_to_char = memoized(utf8.char)
local char_to_codepoint = memoized(utf8.codepoint)
local command_id        = memoized(token.command_id)

local CHAR_GIVEN = command_id["char_given"]
local to_chardef = memoized(function(int)
    return new_token(int, CHAR_GIVEN)
end)

local weak_metatable = { __mode = "kv" }

local token_userdata_to_table
do
    local scratch = node.direct.new("whatsit", "user_defined")
    direct_set_field(scratch, "type", ("t"):byte())
    function token_userdata_to_table(userdata)
        direct_set_data(scratch, userdata)
        return direct_get_data(scratch)
    end
end

local token_userdata_to_string
do
    local scratch = node.direct.new("whatsit", "special")
    function token_userdata_to_string(userdata)
        direct_set_data(scratch, userdata)
        return tostring(direct_get_data(scratch))
    end
end



-------------------------------
--- Property List Functions ---
-------------------------------

-- Module-local storage
local local_prop_storage   = {}
local global_prop_storage  = {}
local MIN_PROP_ID          = 127
local max_prop_id          = MIN_PROP_ID
local MAX_GROUP_LEVEL      = 255

local local_props_by_level = {}
for i = 0, MAX_GROUP_LEVEL do
    local_props_by_level[i] = {}
end

-- Utility functions
local function local_prop_new(name)
    max_prop_id = max_prop_id + 1

    local id = max_prop_id
    local current_level = 0 -- tex_get("currentgrouplevel")

    local_prop_storage[id] = setmetatable({}, weak_metatable)

    local new_level = {}
    local_props_by_level[current_level][id] = new_level
    local_prop_storage[id][current_level]   = new_level

    local packed = (id << 8) | current_level

    token_set_char(name, packed, "global")
end

local function local_prop_pairs(level)
    local meta = getmetatable(level)
    local entry = local_prop_storage[meta.id]

    local current_level = tex_get("currentgrouplevel")
    local all_levels = {}
    for i = 0, current_level do
        all_levels[#all_levels+1] = entry[i]
    end

    local merged = merge_hash(unpack(all_levels))
    return sorted_pairs(merged)
end

local function local_prop_get_mutable(token, value)
    local packed = token_get_mode(token)
    local id = packed >> 8
    local tex_level = packed & 0xFF

    local entry = local_prop_storage[id]
    local current_level = tex_get("currentgrouplevel")

    if (not value) and (tex_level == current_level) then
        return entry[tex_level]
    else
        local new_level = setmetatable(value or {}, {
            __index = entry[tex_level],
            __pairs = local_prop_pairs,
            id      = id,
        })
        local_props_by_level[current_level][id] = new_level
        entry[current_level]                    = new_level

        local csname = token_get_csname(token)
        local new_packed = (id << 8) | current_level
        token_set_char(csname, new_packed)

        return new_level
    end
end

local function local_prop_get_const(token)
    local packed = token_get_mode(token)
    local id = packed >> 8
    local tex_level = packed & 0xFF

    if id < MIN_PROP_ID then
        return {}
    end

    for i = tex_level, 0, -1 do
        local level = local_prop_storage[id][i]
        if level then
            return level
        end
    end
end

-- TeX functions
define_macro {
    module      = "lprop",
    name        = "new",
    arguments   = { "csname", },
    visibility  = "private",
    func = function(name)
        if name:match("^g") or name:match("^c") then
            global_prop_storage[name] = {}
            token_set_char(name, 0, "global")
        elseif name:match("^l") then
            local_prop_new(name)
        end
    end,
}

define_macro {
    module     = "lprop",
    name       = "put",
    arguments  = { "token", "string", "toks", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop  = scan_token()
        local key   = scan_string()
        local value = scan_toks()

        local level = local_prop_get_mutable(prop)
        level[key] = value
    end,
}

define_macro {
    module     = "lprop",
    name       = "gput",
    arguments  = { "csname", "string", "toks", },
    visibility = "public",
    no_scan    = true,
    func = function()
        global_prop_storage[scan_csname()][scan_string()] = scan_toks()
    end,
}

define_macro {
    module     = "lprop",
    name       = "item",
    arguments  = { "token", "string", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop = scan_token()
        local key  = scan_string()
        local value

        local csname = token_get_csname(prop)
        local global_items = global_prop_storage[csname]

        if global_items then
            value = global_items[key]
        else
            local level = local_prop_get_const(prop)
            value = level[key]
        end

        if value then
            write_token(value)
        end
    end,
}

define_macro {
    module     = "lprop",
    name       = "clear",
    arguments  = { "token", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop = scan_token()
        local level = local_prop_get_mutable(prop)

        for key in pairs(level) do
            level[key] = false
        end
    end,
}

define_macro {
    module     = "lprop",
    name       = "gclear",
    arguments  = { "csname", },
    visibility = "public",
    no_scan    = true,
    func = function()
        global_prop_storage[scan_csname()] = {}
    end,
}

define_macro {
    module     = "lprop",
    name       = "gset_eq",
    arguments  = { "csname", "csname", },
    visibility = "public",
    no_scan    = true,
    func = function()
        global_prop_storage[scan_csname()] = global_prop_storage[scan_csname()]
    end,
}

local KEY_TERMINATOR       = char_to_codepoint["="]
local VALUE_TERMINATOR     = char_to_codepoint[","]
local BEGIN_GROUP          = command_id["left_brace"]
local END_GROUP            = command_id["right_brace"]
local SPACER               = command_id["spacer"]
local value_terminator_tok = new_token(VALUE_TERMINATOR, command_id["other"])

local function parse_keyval(level)
    local keyval_toks = scan_toks()
    keyval_toks[#keyval_toks + 1] = value_terminator_tok

    local nest = 0
    local key, value = {}, {}
    local target_key = true

    for i = 1, #keyval_toks do
        local user_tok = keyval_toks[i]
        local cmd = user_tok.command
        local chr = user_tok.mode
        local cs  = user_tok.csname

        -- Always insert macros
        if cs then
            goto insert_token
        end

        -- Handle nesting
        if cmd == BEGIN_GROUP then
            nest = nest + 1
        elseif cmd == END_GROUP then
            nest = nest - 1
        end

        -- Only parse the key-value pair if we're at the outermost level
        if nest == 0 then
            -- Store the key-value pair
            if chr == VALUE_TERMINATOR then
                level[concatenate(key)] = value
                key, value = {}, {}
                target_key = true
                goto continue

            -- End the key and switch to the value
            elseif chr == KEY_TERMINATOR then
                target_key = false
                goto continue

            -- Trim spaces
            elseif cmd == SPACER then
                -- Trim spaces at the beginning
                if target_key and (#key == 0) then
                    goto continue
                elseif (not target_key) and (#value == 0) then
                    goto continue
                end

                -- Trim spaces at the end
                local next_chr = (keyval_toks[i + 1] or {}).mode
                if (not next_chr) or
                    (next_chr == VALUE_TERMINATOR) or
                    (next_chr == KEY_TERMINATOR)
                then
                    goto continue
                end

            -- Skip outermost closing brace
            elseif cmd == END_GROUP then
                goto continue
            end

        -- Skip the outermost opening brace
        elseif nest == 1 then
            if cmd == BEGIN_GROUP then
                goto continue
            end
        end

        -- Insert the token
        ::insert_token::
        if target_key then
            key[#key + 1] = codepoint_to_char[chr]
        else
            value[#value + 1] = user_tok
        end

        ::continue::
    end
end

define_macro {
    module     = "lprop",
    name       = "put_from_keyval",
    arguments  = { "token", "toks", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop  = scan_token()
        local level = local_prop_get_mutable(prop)

        parse_keyval(level)
    end,
}

define_macro {
    module     = "lprop",
    name       = "gput_from_keyval",
    arguments  = { "csname", "toks", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local csname = scan_csname()
        local level = global_prop_storage[csname]
        parse_keyval(level)
    end,
}

local begin_group_tok  = new_token(char_to_codepoint["{"], BEGIN_GROUP)
local end_group_tok = new_token(char_to_codepoint["}"], END_GROUP)

define_macro {
    module     = "lprop",
    name       = "map_function",
    arguments  = { "token", "token", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop   = scan_token()
        local csname = token_get_csname(prop)
        local level  = global_prop_storage[csname] or local_prop_get_const(prop)
        local func   = scan_token()

        local toks, len = {}, 0
        for key, value in pairs(level) do
            if value then
                toks[len + 1] = func
                toks[len + 2] = begin_group_tok
                toks[len + 3] = key
                toks[len + 4] = end_group_tok
                toks[len + 5] = begin_group_tok
                append(toks, value)
                len = #toks + 1
                toks[len + 0] = end_group_tok
            end
        end

        sprint(-2, toks)
    end,
}

define_macro {
    module     = "lprop",
    name       = "concat",
    arguments  = { "token", "token", "token", },
    visibility = "public",
    func = function(out, first, second)
        local first_level = local_prop_get_const(first)
        local second_level = local_prop_get_const(second)
        local_prop_get_mutable(out, merge_hash(first_level, second_level))
    end,
}

define_macro {
    module     = "lprop",
    name       = "gconcat",
    arguments  = { "csname", "csname", "csname", },
    visibility = "public",
    func = function(out, first, second)
        global_prop_storage[out] = merge_hash(
            global_prop_storage[first], global_prop_storage[second]
        )
    end,
}


define_macro {
    module     = "lprop",
    name       = "count",
    arguments  = { "token", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop   = scan_token()
        local csname = token_get_csname(prop)
        local level = global_prop_storage[csname] or local_prop_get_const(prop)

        local count = 0
        for _ in pairs(level) do
            count = count + 1
        end
        write_token(to_chardef[count])
    end,
}

define_macro {
    module     = "lprop",
    name       = "remove",
    arguments  = { "token", "string", },
    visibility = "public",
    no_scan    = true,
    func = function()
        local prop  = scan_token()
        local key   = scan_string()
        local level = local_prop_get_mutable(prop)

        level[key] = false
    end,
}

define_macro {
    module     = "lprop",
    name       = "gremove",
    arguments  = { "csname", "string", },
    visibility = "public",
    no_scan    = true,
    func = function()
        global_prop_storage[scan_csname()][scan_string()] = nil
    end,
}

do
    local every_gc = { __gc = function (t)
        local current_level = tex_get("currentgrouplevel")
        for i = current_level + 1, MAX_GROUP_LEVEL do
            if #local_props_by_level[i] ~= 0 then
                local_props_by_level[i] = {}
            end
        end

        setmetatable({}, getmetatable(t))
    end, }
    setmetatable({}, every_gc)
end


-----------------------
--- Regex Functions ---
-----------------------

-- Convert to special active character csnames
local ACTIVE_CSNAME_PREFIX = "\xEF\xBF\xBF"
local CS_TOKEN_FLAG        = 0x1FFFFFFF
local single_char_cs       = {}

for i = 0, 255 do
    local csname = ACTIVE_CSNAME_PREFIX .. string_char(i)
    token_set_char(csname, 0)
    local cs = create_token(csname).tok - CS_TOKEN_FLAG
    single_char_cs[i] = cs
end

-- Regex patterns
local compile_regex
do
    -- LPeg functions
    local lpeg      = require "lpeg"
    local anywhere  = lpeg.anywhere
    local B         = lpeg.B
    local C         = lpeg.C
    local Carg      = lpeg.Carg
    local Cb        = lpeg.Cb
    local Cc        = lpeg.Cc
    local Cf        = lpeg.Cf
    local Cg        = lpeg.Cg
    local Cmt       = lpeg.Cmt
    local Cp        = lpeg.Cp
    local Cs        = lpeg.Cs
    local Ct        = lpeg.Ct
    local locale    = lpeg.locale
    local match     = lpeg.match
    local P         = lpeg.P
    local R         = lpeg.R
    local S         = lpeg.S
    local lpeg_type = lpeg.type
    local utfR      = lpeg.utfR
    local V         = lpeg.V

    -- Base patterns
    local any     = P(1)
    local escape  = P "\\"
    local l_brace = P "{"
    local r_brace = P "}"
    local space   = (P " ")^-1
    local digits  = R "09"

    local times = function(pattern, minimum, maximum)
        maximum = maximum or minimum
        return pattern^minimum - pattern^(maximum + 1)
    end

    local value = function(...)
        local args = { ... }
        return function()
            return unpack(args)
        end
    end

    -- Atoms
    local atoms   = {}

    -- Hexadecimal escape sequences
    local hex_chars   = R("09", "AF", "af")
    local hex_escape  = escape * (P "x") * space
    local hex_convert = function (hex)
        local char = string_char(tonumber(hex, 16))
        return P(char)
    end

    local hex_pattern = hex_escape * (
        C(times(hex_chars, 2)) +
        (l_brace * C(hex_chars^1) * r_brace)
    ) / hex_convert

    insert(atoms, hex_pattern)

    -- General escape sequences
    for i = 0, 255 do
        local char = string_char(i)

        if char:match("%W") then
            local pattern     = escape * P(char) * space
            local replacement = value(P(char))

            insert(atoms, pattern / replacement)
        end
    end

    -- Special characters
    local special_characters = {
        a = "\a",
        e = "\x1B",
        f = "\f",
        n = "\n",
        r = "\r",
        t = "\t",
    }

    for find_char, replace_char in pairs(special_characters) do
        local pattern     = escape * P(find_char) * space
        local replacement = value(P(replace_char))

        insert(atoms, pattern / replacement)
    end

    -- Dot
    insert(atoms, (P ".") / value(any))

    -- Predefined character classes
    local character_classes = {
        d = { "digits", digits },
        h = { "horizontal space", (S "\t ") },
        s = { "space", (S " \t\n\f\r") },
        v = { "vertical space", (S "\n\v\f\r") },
        w = { "word", R("az", "AZ", "09") + (P "_") },
    }

    local char_class_patterns = P(false)
    for find_char, replace_char in pairs(character_classes) do
        local name, pattern = unpack(replace_char)
        local escape_seq    = escape * P(find_char) * space
        local replacement   = value(pattern)

        insert(atoms, escape_seq / replacement)
        char_class_patterns = char_class_patterns + (escape_seq / replacement)
    end

    for find_char, replace_char in pairs(character_classes) do
        local name, pattern = unpack(replace_char)
        local escape_seq    = escape * P(find_char:upper()) * space
        local replacement   = value(any - pattern)

        insert(atoms, escape_seq / replacement)
        char_class_patterns = char_class_patterns + (escape_seq / replacement)
    end

    -- Posix character classes
    local posix_classes = lpeg.locale()
    local posix_class_name_pattern = P(false)
    for name, pattern in pairs(posix_classes) do
        posix_class_name_pattern = posix_class_name_pattern + (P(name) / name)
    end

    local maybe_negate = C((P "^")^-1)
    local posix_class_pattern = (P "[:") * maybe_negate *
                                C(posix_class_name_pattern) * (P ":]")
    local posix_class_replacement = function(negate, name)
        if negate == "^" then
            return any - posix_classes[name]
        else
            return posix_classes[name]
        end
    end

    insert(atoms, posix_class_pattern / posix_class_replacement)

    -- Arbitrary character classes
    local range_pattern = Ct(C(any) * (P "-") * C(any))
    local class_pattern = (P "[") * maybe_negate * Ct((
                              range_pattern +
                              char_class_patterns +
                              C(any - P "]")
                          )^1) * (P "]")
    local class_replacement = function(negate, chars)
        local ranges = {}
        for _, range in ipairs(chars) do
            if type(range) == "table" then
                insert(ranges, concatenate(range))
            else
                insert(ranges, range:rep(2))
            end
        end

        local pattern = R(unpack(ranges))
        if negate == "^" then
            return any - pattern
        else
            return pattern
        end
    end

    insert(atoms, class_pattern / class_replacement)

    -- Any regular character
    local regular_char_pattern     = posix_classes.alnum
    local regular_char_replacement = function(char)
        return P(char)
    end

    insert(atoms, regular_char_pattern / regular_char_replacement)

    -- Join all the atoms together
    local atoms_pattern = P(false)
    for _, atom in ipairs(atoms) do
        atoms_pattern = atoms_pattern + atom
    end

    -- Quantifiers
    local quantifiers = {}

    -- Zero or one
    insert(quantifiers, { "?", (P "?"), function(pattern)
        return pattern^-1
    end, })

    -- Zero or more
    insert(quantifiers, { "*", (P "*"), function(pattern)
        return pattern^0
    end, })

    -- One or more
    insert(quantifiers, { "+", (P "+"), function(pattern)
        return pattern^1
    end, })

    -- Exactly n
    insert(quantifiers, { "n", l_brace * C(digits^1) * r_brace, times, })

    -- n or more
    insert(quantifiers, {
        "n+", l_brace * C(digits^1) * (P ",") * space * r_brace,
        function(pattern, n)
            return pattern^n
        end,
    })

    -- n to m
    insert(quantifiers, {
        "n-m", l_brace * C(digits^1) * (P ",") * space * C(digits^1) * r_brace,
        times,
    })

    -- No quantifier
    insert(quantifiers, { "", P(true), P, })

    -- Join all the quantifiers together
    local quantifiers_pattern      = P(false)
    local quantifiers_replacements = {}
    for _, quantifier_pair in ipairs(quantifiers) do
        local name, quantifier, replacement = unpack(quantifier_pair)
        quantifiers_pattern = quantifiers_pattern + (quantifier / function(...)
            return name, ...
        end)
        quantifiers_replacements[name] = replacement
    end

    local function replace_quantifier(atom, quantifier, ...)
        return quantifiers_replacements[quantifier](atom, ...)
    end

    -- Create the full grammar to parse the regex
    local regex_pattern = P {
        "regex",
        atom       = atoms_pattern,
        quantifier = quantifiers_pattern,
        group      = P("TODO"),
        item       = (V "atom") + (V "group"),
        section    = ((V "item") * space * (V "quantifier")) /
                     replace_quantifier,
        regex      = Cf(Cc(true) * (V "section")^0, function(...)
            if select("#", ...) == true then
                return function(text)
                    return false
                end
            end

            local pattern = P(true)
            for _, rule in ipairs { ... } do
                pattern = pattern * rule
            end

            return pattern
        end),
    }

    function compile_regex(regex)
        if not regex:match("%S") then
            return function(text)
                return text
            end
        end

        local pattern = match(regex_pattern, regex)
        if type(pattern) == "string" then
            return pattern
        elseif type(pattern) == "boolean" then
            return function(text)
                return false
            end
        else
            return function(text)
                return match(anywhere(pattern), text)
            end
        end
    end

    -- TODO:
    --   - Groups
    --   - Alternation
    --   - Lazy quantifiers
    --   - Catcodes
    --   - Control Sequences
    --   - Begin/end (^/\A and $/\Z/\z)
    --   - Weird escapes: \K, \b, \B, \G
    --   - Case-insensitive options
    --   - Replacement text escapes
end

local regex_storage = {}

define_macro {
    module      = "lregex",
    name        = "set",
    arguments   = { "csname", "string" },
    visibility  = "public",
    no_scan     = true,
    func = function()
        local name      = scan_csname()
        local regex_str = scan_argument(false)
        local regex_pat = compile_regex(regex_str)
        regex_storage[name] = regex_pat
    end,
}

define_macro {
    module      = "lregex",
    name        = "match_p",
    arguments   = { "csname", "string" },
    visibility  = "public",
    no_scan     = true,
    func = function()
        local name      = scan_csname()
        local regex_pat = regex_storage[name]
        local str       = scan_argument(false)

        local match = regex_pat(str)
        if match then
            write_token(to_chardef[1])
        else
            write_token(to_chardef[0])
        end
    end,
}
