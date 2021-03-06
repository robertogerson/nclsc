#!/usr/bin/env lua
--[[ Copyright (C) 2015 Roberto Azevedo

This file is part of ncls3d.

ncls3d is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

ncls3d is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with ncls3d. If not, see <http://www.gnu.org/licenses/>.
--]]

-- Add deps path to the package.path.
-- Thus, the dependencies will be found
package.path = package.path .. ";./deps/?.lua;./deps/?/?.lua;./deps/?/src/?.lua;./deps/slaxml/?.lua"

local inspect   = require "inspect"
local util      = require "util"
local slaxml    = require "slaxdom_ext"
local templates = require "templates_xml"

-- Some global definitions
local VERSION = "1.0"
local STR_USAGE = "ncls3d.lua --input=$XML_IN_PATH --output=$XML_OUT_PATH"
local USER_CUSTOM_DEPTH = 1.0
local MAX_NEG_DISPARITY = 0.02
local MAX_POS_DISPARITY = 0.01
local SUFFIX = "_right"
local USE_MIRROR = true
local USE_NCLUA_DEPTH_CONTROL = false
local USE_ZINDEX = false

-- Add a suffix value to all the values of the attributes in attr_names.
-- @param xml_el
-- @param attr_names
-- @param suffix
-- @param recursive
function add_suffix_to_attr(xml_el, attr_names, suffix, recursive)
  if xml_el.attr then
    for x, attr in pairs(xml_el.attr) do
      if attr_names[attr.name] ~= nil then
      	if attr.value == nil then
          attr.value = ""
        end
        attr.value = attr.value .. suffix
      end
    end
  end
  
  if xml_el.kids then
    for x, child in pairs (xml_el.kids) do
      add_suffix_to_attr (child, attr_names, suffix, recursive)
    end
  end
end

-- Add a prefix value to all the values of the attributes in attr_names.
-- @param xml_el
-- @param attr_names
-- @param suffix
-- @param recursive
function add_prefix_to_attr(xml_el, attr_names, prefix, recursive)
  if xml_el.attr then
    for x, attr in pairs(xml_el.attr) do
      if attr_names[attr.name] ~= nil then
        if attr.value == nil then
          attr.value = ""
        end
        attr.value = prefix .. attr.value
      end
    end
  end
  
  if xml_el.kids then
    for x, child in pairs (xml_el.kids) do
      add_prefix_to_attr (child, attr_names, suffix, recursive)
    end
  end
end

-- Update media properties for both, left and right media objects
-- For now, it handle only percentage values
-- @param left_el
-- @param right_el
function update_media_properties (left_el, right_el)
  local attr_name_tbl, attr_value_tbl;
  -- update original (left) element
  for k, child in pairs(left_el.kids) do
    if (child.name == "property" ) then
      -- search for tables related to "name" and "value" attributes
      local prop_name = slaxml:get_attr(child, "name")
      local prop_value = slaxml:get_attr(child, "value")

      -- if there is a width, left or right property we must update it
      if (prop_name == "width") or (prop_name == "left") then
        slaxml:set_attr( child, "value",
          tostring(double_from_percent(prop_value) * 100 / 2).."%")
      elseif (prop_name == "right") then
        slaxml:set_attr( child, "value",
          tostring(double_from_percent(prop_value) * 100 / 2 + 50).."%")
      end
    end
  end
  
  -- look for stereo_disparity attribute
  local disparity = 0;
  for k, child in pairs(right_el.kids) do
    if child.name == "property" then
      local prop_name = slaxml:get_attr(child, "name")
      local prop_value = slaxml:get_attr(child, "value")
      
      if prop_name == "depth" then
        disparity = tonumber(prop_value)
      end
    end
  end
  
  -- update cloned (right) element
  for k, child in pairs(right_el.kids) do
    if (child.name == "property" ) then
      local prop_name = slaxml:get_attr(child, "name")
      local prop_value = slaxml:get_attr(child, "value")

      -- Adapt disparity based on MIN_DISPARITY or MAX_DISPARITY
      local adapted_disparity = 0;
      if (disparity >= 0) then
        adapted_disparity = (-1.0) * disparity * MAX_POS_DISPARITY * USER_CUSTOM_DEPTH
      else
        adapted_disparity = (-1.0) * disparity * MAX_NEG_DISPARITY * USER_CUSTOM_DEPTH
      end
      
      -- if there is a left, right, or width properties we must update it
      if (prop_name == "width") then
          slaxml:set_attr( 
            child,
            "value",
            tostring(double_from_percent(prop_value) * 100/2).."%")
      elseif prop_name == "left" then
          update_left = true
          slaxml:set_attr(
            child,
            "value",
            tostring((double_from_percent(prop_value)/2 + 0.5 +
                      adapted_disparity) * 100 ).."%") -- need to add disparity

      elseif prop_name == "right" then
          slaxml:set_attr(
            child,
            "value",
            tostring((double_from_percent(prop_value)/2 -
                      adapted_disparity) * 100 ).."%") -- need to add disparity
      end
    end
  end
end

function add_property_if_it_doesnt_exist(media_el)
  local add_property_tbl = { ["left"] = "0%",
                             ["width"] = "100%" }

  for k, v in pairs(add_property_tbl) do 
    local found = false; 
    for _, child in pairs(media_el.kids) do
      if child.type == "element" then
        local prop_name = slaxml:get_attr(child, "name")

        if prop_name == k or
           prop_name == "bounds" -- If I only need bounds
        then
          found  = true
          break
        end
      end
    end

    -- in case we do not found the <property>, we should add it
    if not found then
      local prop_el = {}
      prop_el.attr = {}
      prop_el.name = "property"
      prop_el.type = "element"
      slaxml:set_attr(prop_el, "name", k)
      slaxml:set_attr(prop_el, "value", v)

      -- add the property
      table.insert(media_el.kids, prop_el)
    end
  end

  return media_el
end

-- Clone a <media> element, updating its src attribute and its spatial properties
function clone_ncl_media ( media_el )
  assert(media_el.name == "media")

  -- \fixme This is not a really interesting thing to do!
  if not slaxml:get_attr(media_el, "descriptor") then
    add_property_if_it_doesnt_exist(media_el)
  end
  
  local media_right = table.deepcopy(media_el) -- clone the media element
  local mirror_id = slaxml:get_attr(media_right, "id")
  add_suffix_to_attr(media_right, {id=true, descriptor=true}, SUFFIX, false)
		  
  -- update source attribute
  if USE_MIRROR then
    slaxml:set_attr(media_right, "src", "ncl-mirror://" .. mirror_id)
  end
  
  -- update properties in the left and right element
  update_media_properties (media_el, media_right)
  return media_right
end

-- Add an NCL <media> element responsible to control the depth of media_el
-- element.
-- @param media_el The media element that 
-- @return the <media> element responsible to control the depth of media_el.
function create_nclua_depth_control(media_el)
  assert (media_el.name == "media")
  local str_id = slaxml:get_attr(media_el, "id")
  local orig_bounds = "0%,0%,100%,100%"
  local orig_depth = "0"
  
  -- get default media properties
  for k, v in pairs(media_el.kids) do
    if v.type == "element" then
      local name =  slaxml:get_attr(v, "name")

      if name == "depth" then
        orig_depth = slaxml:get_attr(v, "value")  or orig_depth
      elseif name == "bounds" then
        orig_bounds = slaxml:get_attr(v, "value") or orig_bounds
      end
    end
  end

  -- TODO: We can do better than that. Maybe, search the functions in templates
  -- table 
  local depth_control_media_start = templates:get_depth_control_media_start(str_id)
  local depth_control_media = templates:get_depth_control_media(str_id)
  local depth_control_link_left = templates:get_link_update_left(str_id)
  local depth_control_link_right = templates:get_link_update_right(str_id)
  local depth_control_link_stop = templates:get_link_stop_depth_control(str_id)
  local link_set_depth_defaults = 
          templates:get_link_set_depth_defaults(str_id, orig_depth, orig_bounds)
  
  return { depth_control_media_start, 
           depth_control_media,
           depth_control_link_left,
           depth_control_link_right,
           depth_control_link_stop,
           link_set_depth_defaults }
end

function update_regions_with_disparity(region_el)
  assert(region_el.name == "region")
  -- search depth attribute
  local depth = 0
  for k, v in pairs(region_el.attr) do
    if v.name == "depth" then
      depth = tonumber(v.value)
    end
  end
  
  -- Adapt disparity based on MIN_DISPARITY or MAX_DISPARITY
  local adapted_disparity = 0;
  
  if (depth >= 0) then
    adapted_disparity = (-1.0) * depth * MAX_POS_DISPARITY * USER_CUSTOM_DEPTH
  else
    adapted_disparity = (-1.0) * depth * MAX_NEG_DISPARITY * USER_CUSTOM_DEPTH
  end
  
  for k, v in pairs(region_el.attr) do
    if v.name == "left" then
      v.value = tostring((double_from_percent(v.value) + adapted_disparity) * 100) .. "%"
    elseif v.name == "right" then
      v.value = tostring((double_from_percent(v.value) - adapted_disparity) * 100) .. "%"
    end
  end
  
  for k, v in pairs(region_el.kids) do
    if v.name == "region" then
      update_regions_with_disparity(v)
    end
  end
end

-- Clone a <port> element.
-- @param port_el The original <port> element.
-- @return The cloned <port> element. 
function clone_ncl_port(port_el)
  assert(port_el.name == "port")
  local port_right = table.deepcopy (port_el)
  
  -- search for and update the XML attributes for port element
  add_suffix_to_attr(port_right, {id = true, component = true}, SUFFIX, false)
  
  return port_right
end

-- Clone the regions inside a <regionBase> element.
-- @param region_base_el The <regionBase> element table.
-- @return void
function clone_ncl_regions(region_base_el)
  assert(region_base_el.name == "regionBase")
  local original_regions = region_base_el.kids
  
  -- remove original regions
  region_base_el.kids = {}
  local regions_left = {name="region", type="element",
                        attr = {{name = "id", value="regions_left"},
                                {name = "left", value="0%"},
                                {name = "top", value="0%"},
                                {name = "width", value="50%"},
                                {name = "height", value="100%"}}}
  
  regions_left.kids = original_regions
  
  local regions_right = {name="region", type="element",
                         attr = {{name = "id", value="regions"},
                                 {name = "left", value="50%"},
                                 {name = "top", value="0%"},
                                 {name = "width", value="50%"},
                                 {name = "height", value="100%"}}}
                                 
  regions_right.kids = table.deepcopy(original_regions)
  add_suffix_to_attr(regions_right, {id = true}, SUFFIX, true)
  
  update_regions_with_disparity(regions_right)
  
  -- TODO: Update cloned regions id
                                 
  table.insert(region_base_el.kids, regions_left)
  table.insert(region_base_el.kids, regions_right)
end

-- Returns a cloned NCL <descriptor> element.
-- @param descriptor_el The original <descriptor> element.
function clone_ncl_descriptor(descriptor_el)
  assert(descriptor_el.name == "descriptor")
  local descriptor_right = table.deepcopy(descriptor_el)
  add_suffix_to_attr( descriptor_right, 
                      {id = true, region = true},
                      SUFFIX,
                      false)

  return descriptor_right
end

-- Returns a cloned <bind> element. The component attribute should point to
-- the right-side element.
-- @param bind_el The original <bind> element.
function clone_ncl_bind(doc, bind_el)
  assert(bind_el.name == "bind")
  -- should not replicate set, it must be updated to be setted for depth_control_media
  -- Mainly because of animations!
  local actions = {start = 1, stop = 1}
  
  -- Set will also be cloned if we do not use NCLua depth control
  if not USE_NCLUA_DEPTH_CONTROL then
      actions["set"] = 1
  end
  
  local role = slaxml:get_attr(bind_el, "role")

  if role ~= nil and actions[role] ~= nil then
    -- clone only if the component is a media (e.g. does not clone for context,
    -- switch, etc.)
    -- TODO: This is not completely right. We should clone the bind only if the
    -- media that is being pointed changes!!!
    local component = slaxml:get_attr(bind_el, "component")
    if component then
      local component_el = slaxml:get_elem_by_attr(doc, "id", component)
      -- print (component, component_el.name)
      if component_el.name == "media" then
        local bind_right = table.deepcopy(bind_el)
        add_suffix_to_attr(bind_right, {component = true, descriptor = true}, SUFFIX, false)
        return bind_right
      end
    end
  end
  
  return nil
end

-- Updates an NCL bind which role is a set for a property in the left element
-- @param bind_el The <bind> element.
function update_ncl_bind(bind_el)
  assert (bind_el.name == "bind")
  local actions = {set = 1}
  local role = slaxml:get_attr(bind_el, "role")

  if role ~= nil and actions[role] ~= nil then
    add_suffix_to_attr(bind_el, {component = true}, "_depth_control", false)
    add_prefix_to_attr(bind_el, {interface = true}, "orig_", false)
    return true
  end

  return false
end

function import_connector_base (xml_el)
  local import = {
      type = "element",
      name = "importBase",
      attr = { {name = "alias", value = "ncls3dbase"},
               {name = "documentURI", value = "../media/connBase.ncl"} } }

  table.insert (xml_el.kids, import)
end

-- Main function to generate stereo application from the original NCL document
-- @param doc The root document table.
-- @param xml_el The current xml element being parsed.
function generate_stereo ( doc, xml_el )
  -- print ("Parsing:", xml_el.type, xml_el.name)
  local to_add = {}
  -- Look for elements in a recursive way
  if xml_el and xml_el.kids then
    for k, xml_child in pairs (xml_el.kids) do
      -- print (xml_child.name)
      if xml_child.type == "element" then
        -- if we find a MEDIA element duplicate it
        if(xml_child.name == "media") then
          -- settings does not need to be duplicated
          local isSettings = false
          if slaxml:get_attr(xml_child, "type") == "application/x-ginga-settings" then
            isSettings = true
          end
          -- I need to duplicate the media object
          if not isSettings then
            local media_right = clone_ncl_media(xml_child)
            table.insert(to_add, media_right)
            
            if USE_NCLUA_DEPTH_CONTROL then
              local depth_control_elements = create_nclua_depth_control(xml_child)
              for k, v in pairs(depth_control_elements) do
                table.insert(to_add, v)
              end
            end
          end
        elseif (xml_child.name == "port") then
          -- I need to duplicate the port object
          local port_right = clone_ncl_port(xml_child)
          table.insert(to_add, port_right)
        elseif (xml_child.name == "regionBase") then
          clone_ncl_regions(xml_child)
        elseif (xml_child.name == "descriptor") then
          local descriptor_right = clone_ncl_descriptor(xml_child)
          table.insert(to_add, descriptor_right)
        elseif (xml_child.name == "bind") then
          local bind_right = clone_ncl_bind(doc, xml_child)
          if bind_right ~= nil then
            table.insert(to_add, bind_right)
          end
          if USE_NCLUA_DEPTH_CONTROL then
            update_ncl_bind(xml_child)
          end
        elseif xml_child.name == "connectorBase" then
          import_connector_base(xml_child)
        end
      end
      
      generate_stereo(doc, xml_child)
    end

    -- TODO: Add a comment saying that this is generated by NCLS3D
    for k, v in pairs (to_add) do
      table.insert(xml_el.kids, #xml_el.kids, v)
    end
  end
end

local argparse = require "argparse"
local parser = argparse()
  :description ("ncls3d is a lua script to convert an NCL document to its "
                .. "stereoscopic version.")
parser:argument "input"
  :description "Input file."
parser:flag "-d" "--usedepth"
  :description "Use NCLua depth media control."
parser:flag "-m" "--usemirror"
  :description "Use ncl-mirror:// schema to cloned media objects."
parser:option "-p" "--max-pos-disparity"
  :description ("Defines the *maximum positive disparity* that must be used.\n"
               .. "The maximum positive and negative disparity should be a \n"
               .. "double in the range [0.0, 1.0]. \n"
               .. "0.0 means 0% of the screen and 1.0 means 100%.\n"
               .. "The default value is " .. MAX_POS_DISPARITY
               .. " (or ".. MAX_POS_DISPARITY * 100 .. "%).")
parser:option "-n" "--max-neg-disparity"
  :description ("Defines the *maximum negative disparity* that must be used.\n"
               .. "The maximum positive and negative disparity should be a \n"
               .. "double in the range [0.0, 1.0]. \n"
               .. "0.0 means 0% of the screen and 1.0 means 100%.\n"
               .. "The default value is " .. MAX_NEG_DISPARITY
               .. " (or ".. MAX_NEG_DISPARITY * 100 .. "%).")
parser:option "-o" "--output"
  :description "Output file."

-- Main
function main()
  -- Handle arguments
  local args = parser:parse()

  -- Open file
  local f = assert(io.open(args["input"], "r"))
  local xml_content = f:read("*all")
  f:close()

  -- Parse XML and print results
  local doc = slaxml:dom(xml_content,{ simple=true })
  if (doc) then
    print ("-- Parsing success.\n")
  end

  -- Update global parameters
  USE_NCLUA_DEPTH_CONTROL = args["usedepth"]
  USE_MIRROR = args["usemirror"]

  if args["max_pos_disparity"] then
    MAX_POS_DISPARITY = tonumber (args["max_pos_disparity"])
  end

  if args["max_neg_disparity"] then
    MAX_NEG_DISPARITY = tonumber (args["max_neg_disparity"])
  end
 
  generate_stereo (doc, doc)
  -- print (inspect(doc))
  if args["output"] then
    print ("Ouput writed to " .. args["output"])
    f = assert(io.open(args["output"], "w"))
    f:write(slaxml:serialize(doc, -1, "  "))
    f:close()
  else
    print ("You didn't provide an output file. The output is:")
    print (slaxml:serialize(doc, -1, " "))
  end
end

-- Start the program
main()

