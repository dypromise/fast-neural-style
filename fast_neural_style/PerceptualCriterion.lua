require "torch"
require "nn"

require "fast_neural_style.ContentLoss"
require "fast_neural_style.StyleLoss"
require "fast_neural_style.HistLoss"
require "fast_neural_style.StyleLossGuided"
require "fast_neural_style.DeepDreamLoss"

local layer_utils = require "fast_neural_style.layer_utils"

local crit, parent = torch.class("nn.PerceptualCriterion", "nn.Criterion")

--[[
Input: args is a table with the following keys:
- cnn: A network giving the base CNN.
- content_layers: An array of layer strings
- content_weights: A list of the same length as content_layers
- style_layers: An array of layers strings
- style_weights: A list of the same length as style_layers
- agg_type: What type of spatial aggregaton to use for style loss;
"mean" or "gram"
- deepdream_layers: Array of layer strings
- deepdream_weights: List of the same length as deepdream_layers
- loss_type: Either "L2", or "SmoothL1"
--]]
function crit:__init(args)
  args.content_layers = args.content_layers or {}
  args.style_layers = args.style_layers or {}
  args.hist_layers = args.hist_layers or {}
  args.deepdream_layers = args.deepdream_layers or {}

  self.net = args.cnn
  self.net:evaluate()
  self.content_loss_layers = {}
  self.style_loss_layers = {}
  self.hist_loss_layers = {}
  self.deepdream_loss_layers = {}

  -- Set up content loss layers
  for i, layer_string in ipairs(args.content_layers) do
    local weight = args.content_weights[i]
    local content_loss_layer = nn.ContentLoss(weight, args.loss_type)
    layer_utils.insert_after(self.net, layer_string, content_loss_layer)
    table.insert(self.content_loss_layers, content_loss_layer)
  end

  -- Set up DeepDream layers
  for i, layer_string in ipairs(args.deepdream_layers) do
    local weight = args.deepdream_weights[i]
    local deepdream_loss_layer = nn.DeepDreamLoss(weight)
    layer_utils.insert_after(self.net, layer_string, deepdream_loss_layer)
    table.insert(self.deepdream_loss_layers, deepdream_loss_layer)
  end

  -- Set up style loss layers
  if args.agg_type == "guided_gram" then
    local guided_net = nn.Sequential()
    local parallel = nn.ParallelTable()
    local img_path = nn.Sequential()
    local guide_path = nn.Sequential()
    local next_style_ndx = 1
    local next_content_ndx = 1
    for i = 1, #self.net do
      if (next_style_ndx <= #args.style_layers or next_content_ndx <= #args.content_layers) then
        local layer = self.net:get(i)
        local layer_type = torch.type(layer)
        img_path:add(layer)
        if layer_type == "nn.SpatialMaxPooling" then
          -- use average pooling for downsampling of mask
          local kW, kH, dW, dH, padW, padH, ceil_mode =
            layer.kW,
            layer.kH,
            layer.dW,
            layer.dH,
            layer.padW,
            layer.padH,
            layer.ceil_mode
          local ave_pool = nn.SpatialAveragePooling(kW, kH, dW, dH, padW, padH)
          ave_pool.ceil_mode = ceil_mode
          guide_path:add(ave_pool)
        else
          guide_path:add(nn.Identity())
        end
        if next_style_ndx <= #args.style_layers then
          if layer == layer_utils.get_layer(self.net, args.style_layers[next_style_ndx]) then
            local weight = args.style_weights[next_style_ndx]
            local style_loss_layer = nn.StyleLossGuided(weight, args.loss_type)
            next_style_ndx = next_style_ndx + 1
            parallel:add(img_path:clone()):add(guide_path:clone())
            guided_net:add(parallel:clone()):add(style_loss_layer)
            table.insert(self.style_loss_layers, style_loss_layer)
            parallel = nn.ParallelTable()
            img_path = nn.Sequential()
            guide_path = nn.Sequential()
          end
        end
        if next_content_ndx <= #args.content_layers then
          if layer_type == "nn.ContentLoss" then
            next_content_ndx = next_content_ndx + 1
            parallel:add(img_path:clone()):add(guide_path:clone())
            guided_net:add(parallel:clone())
            -- hack to keep contentloss in content_loss_layers table
            guided_net.modules[#guided_net].modules[1].modules[1] = layer
            parallel = nn.ParallelTable()
            img_path = nn.Sequential()
            guide_path = nn.Sequential()
          end
        end
      end
    end
    guided_net:add(nn.JoinTable(1, 3))
    self.net = guided_net
  else
    for i, layer_string in ipairs(args.style_layers) do
      local weight = args.style_weights[i]
      local style_loss_layer = nn.StyleLoss(weight, args.loss_type)
      layer_utils.insert_after(self.net, layer_string, style_loss_layer)
      table.insert(self.style_loss_layers, style_loss_layer)
    end
  end

  -- Set up histogram loss layers
  for i, layer_string in ipairs(args.hist_layers) do
    local weight = args.hist_weights[i]
    local hist_loss_layer = nn.HistLoss(weight)
    layer_utils.insert_after(self.net, layer_string, hist_loss_layer)
    table.insert(self.hist_loss_layers, hist_loss_layer)
  end

  if args.agg_type ~= "guided_gram" then
    layer_utils.trim_network(self.net)
  end

  self.grad_net_output = torch.Tensor()
end

--[[
target: Tensor of shape (1, 3, H, W) giving pixels for style target image
--]]
function crit:setStyleTarget(target)
  for i, content_loss_layer in ipairs(self.content_loss_layers) do
    content_loss_layer:setMode("none")
  end
  for i, hist_loss_layer in ipairs(self.hist_loss_layers) do
    hist_loss_layer:setMode("none")
  end
  for i, style_loss_layer in ipairs(self.style_loss_layers) do
    style_loss_layer:setMode("capture")
  end
  self.net:forward(target)
end

--[[
target: Tensor of shape (1, 3, H, W) giving pixels for style target image
--]]
function crit:setHistTarget(target)
  for i, content_loss_layer in ipairs(self.content_loss_layers) do
    content_loss_layer:setMode("none")
  end
  for i, style_loss_layer in ipairs(self.style_loss_layers) do
    style_loss_layer:setMode("none")
  end
  for i, hist_loss_layer in ipairs(self.hist_loss_layers) do
    hist_loss_layer:setMode("capture")
  end
  self.net:forward(target)
end

--[[
target: Tensor of shape (N, 3, H, W) giving pixels for content target images
--]]
function crit:setContentTarget(target)
  for i, style_loss_layer in ipairs(self.style_loss_layers) do
    style_loss_layer:setMode("none")
  end
  for i, hist_loss_layer in ipairs(self.hist_loss_layers) do
    hist_loss_layer:setMode("none")
  end
  for i, content_loss_layer in ipairs(self.content_loss_layers) do
    content_loss_layer:setMode("capture")
  end
  self.net:forward(target)
end

function crit:setStyleWeight(weight)
  for i, style_loss_layer in ipairs(self.style_loss_layers) do
    style_loss_layer.strength = weight
  end
end

function crit:setHistWeight(weight)
  for i, hist_loss_layer in ipairs(self.hist_loss_layers) do
    hist_loss_layer.strength = weight
  end
end

function crit:setContentWeight(weight)
  for i, content_loss_layer in ipairs(self.content_loss_layers) do
    content_loss_layer.strength = weight
  end
end

--[[
Inputs:
- input: Tensor of shape (N, 3, H, W) giving pixels for generated images
- target: Table with the following keys:
- content_target: Tensor of shape (N, 3, H, W)
- style_target: Tensor of shape (1, 3, H, W)
--]]
function crit:updateOutput(input, target)
  if target.content_target then
    self:setContentTarget(target.content_target)
  end
  if target.style_target then
    self.setStyleTarget(target.style_target)
  end
  if target.hist_target then
    self.setHistTarget(target.hist_target)
  end

  -- Make sure to set all content and style loss layers to loss mode before
  -- running the image forward.
  for i, content_loss_layer in ipairs(self.content_loss_layers) do
    content_loss_layer:setMode("loss")
  end
  for i, style_loss_layer in ipairs(self.style_loss_layers) do
    style_loss_layer:setMode("loss")
  end
  for i, hist_loss_layer in ipairs(self.hist_loss_layers) do
    hist_loss_layer:setMode("loss")
  end

  local output = self.net:forward(input)

  -- Set up a tensor of zeros to pass as gradient to net in backward pass
  self.grad_net_output:resizeAs(output):zero()

  -- Go through and add up losses
  self.total_content_loss = 0
  self.content_losses = {}
  self.total_style_loss = 0
  self.style_losses = {}
  self.total_hist_loss = 0
  self.hist_losses = {}
  for i, content_loss_layer in ipairs(self.content_loss_layers) do
    self.total_content_loss = self.total_content_loss + content_loss_layer.loss
    table.insert(self.content_losses, content_loss_layer.loss)
  end
  for i, style_loss_layer in ipairs(self.style_loss_layers) do
    self.total_style_loss = self.total_style_loss + style_loss_layer.loss
    table.insert(self.style_losses, style_loss_layer.loss)
  end
  for i, hist_loss_layer in ipairs(self.hist_loss_layers) do
    self.total_hist_loss = self.total_hist_loss + hist_loss_layer.loss
    table.insert(self.hist_losses, hist_loss_layer.loss)
  end

  self.output = self.total_style_loss + self.total_content_loss + self.total_hist_loss
  return self.output
end

function crit:updateGradInput(input, target)
  self.gradInput = self.net:updateGradInput(input, self.grad_net_output)
  return self.gradInput
end
