require "torch"
require "loadcaffe"
require "optim"
require "image"
require "hdf5"

require "fast_neural_style.DataLoader"
require "fast_neural_style.PerceptualCriterion"
require "fast_neural_style.DepthCriterion"

local utils = require "fast_neural_style.utils"
local preprocess = require "fast_neural_style.preprocess"
local models = require "fast_neural_style.models"

use_display, display = pcall(require, "display")
if not use_display then
  print("torch.display not found. unable to plot")
end

local cmd = torch.CmdLine()

--[[
Train a feedforward style transfer model
--]]
-- Generic options
cmd:option("-arch", "c9s1-32,d64,d128,R128,R128,R128,R128,R128,u64,u32,c3s1-3")
cmd:option("-use_instance_norm", 1)
cmd:option("-task", "style", "style|upsample")
cmd:option("-h5_file", "data/ms-coco-512.h5")
cmd:option("-padding_type", "reflect-start")
cmd:option("-tanh_constant", 150)
cmd:option("-preprocessing", "vgg")
cmd:option("-resume_from_checkpoint", "")
cmd:option("-loss_type", "L2", "L2|SmoothL1")

-- Generic loss function options
cmd:option("-pixel_loss_type", "L1", "L2|L1|SmoothL1")
cmd:option("-pixel_loss_weight", 0.0)
cmd:option("-percep_loss_weight", 1.0)
cmd:option("-depth_loss_weight", 1.0)
cmd:option("-tv_strength", 1e-6)

-- Options for feature reconstruction loss
cmd:option("-content_weights", "1.0")
cmd:option("-content_layers", "23") --relu4_2

-- Options for style reconstruction loss
cmd:option("-style_image", "images/styles/candy.jpg")
cmd:option("-style_image_guides", "path/to/hdf5file")
cmd:option("-style_image_size", 600)
cmd:option("-style_weights", "10.0")
cmd:option("-style_layers", "4,9,14,23") --relu1_2, relu2_2, relu3_2, relu4_2
cmd:option("-style_target_type", "gram", "gram|mean|guided_gram")

-- Options for histogram layers
cmd:option("-histogram_weights", "")
cmd:option("-histogram_layers", "")

-- Options for depth loss layers
cmd:option("-depth_network", "relative-depth/results/hourglass3/AMT_from_205315_1e-4_release/Best_model_period2.t7")
cmd:option("-depth_layers", "5")
cmd:option("-depth_weights", "5.0")

-- Upsampling options
cmd:option("-upsample_factor", 4)

-- Optimization
cmd:option("-num_iterations", 40000)
cmd:option("-max_train", -1)
cmd:option("-batch_size", 2)
cmd:option("-learning_rate", 1e-3)
cmd:option("-lr_decay_every", 4000)
cmd:option("-lr_decay_factor", 0.8)
cmd:option("-weight_decay", 0)

-- Checkpointing
cmd:option("-checkpoint_name", "checkpoint")
cmd:option("-checkpoint_every", 1000)
cmd:option("-num_val_batches", 10)

-- Backend options
cmd:option("-gpu", 0)
cmd:option("-use_cudnn", 1)
cmd:option("-backend", "cuda", "cuda|opencl")

-- Vgg19 defination and weights
cmd:option("-proto_file", "models/trained/vgg19/VGG_ILSVRC_19_layers_deploy.prototxt", "Pretrained")
cmd:option("-model_file", "models/trained/vgg19/VGG_ILSVRC_19_layers.caffemodel")

-- Website Display
cmd:option("-display_port", 8000, "specify port to show graphs")

function main()
  local opt = cmd:parse(arg)

  -- Config display port
  if use_display then
    display.configure({port = opt.display_port})
  end

  -- Parse layer strings and weights
  opt.content_layers, opt.content_weights = utils.parse_layers(opt.content_layers, opt.content_weights)
  opt.style_layers, opt.style_weights = utils.parse_layers(opt.style_layers, opt.style_weights)
  opt.histogram_layers, opt.histogram_weights = utils.parse_layers(opt.histogram_layers, opt.histogram_weights)
  opt.depth_layers, opt.depth_weights = utils.parse_layers(opt.depth_layers, opt.depth_weights)

  -- Figure out preprocessing
  if not preprocess[opt.preprocessing] then
    local msg = 'invalid -preprocessing "%s"; must be "vgg" or "resnet"'
    error(string.format(msg, opt.preprocessing))
  end
  preprocess = preprocess[opt.preprocessing]

  -- Figure out the backend
  local dtype, use_cudnn = utils.setup_gpu(opt.gpu, opt.backend, opt.use_cudnn == 1)

  ---------------------------------------
  -- Load style image guide if necessary
  ---------------------------------------
  local style_image_guides = nil
  local n_guides = 0
  if opt.style_target_type == "guided_gram" then
    -- Load guides
    local f = hdf5.open(opt.style_image_guides, "r")
    style_image_guides = f:all()["guides"]
    f:close()
    n_guides = style_image_guides:size(1)
  end

  ---------------------------------------
  -- Build the model
  ---------------------------------------
  local model = nil
  if opt.resume_from_checkpoint ~= "" then
    print("Loading checkpoint from " .. opt.resume_from_checkpoint)
    model = torch.load(opt.resume_from_checkpoint).model:type(dtype)
  else
    print("Initializing model from scratch")
    model = models.build_model(opt, 3 + n_guides):type(dtype)
  end
  if use_cudnn then
    cudnn.convert(model, cudnn)
  end
  model:training()
  print(model)

  -- Set up the pixel loss function
  local pixel_crit
  if opt.pixel_loss_weight > 0 then
    if opt.pixel_loss_type == "L2" then
      pixel_crit = nn.MSECriterion():type(dtype)
    elseif opt.pixel_loss_type == "L1" then
      pixel_crit = nn.AbsCriterion():type(dtype)
    elseif opt.pixel_loss_type == "SmoothL1" then
      pixel_crit = nn.SmoothL1Criterion():type(dtype)
    end
  end

  -- Set up the perceptual loss function
  local percep_crit
  if opt.percep_loss_weight > 0 then
    -- local loss_net = torch.load(opt.loss_network)
    local loss_net = loadcaffe.load(opt.proto_file, opt.model_file, "nn")
    loss_net = cudnn.convert(loss_net, nn):float()

    local crit_args = {
      cnn = loss_net,
      style_layers = opt.style_layers,
      style_weights = opt.style_weights,
      content_layers = opt.content_layers,
      content_weights = opt.content_weights,
      hist_layers = opt.histogram_layers,
      hist_weights = opt.histogram_weights,
      loss_type = opt.loss_type,
      agg_type = opt.style_target_type
    }
    percep_crit = nn.PerceptualCriterion(crit_args):type(dtype)

    if opt.task == "style" then
      -- Load the style image and set it
      local style_image = image.load(opt.style_image, 3, "float")
      style_image = image.scale(style_image, opt.style_image_size)
      local H, W = style_image:size(2), style_image:size(3)
      style_image = preprocess.preprocess(style_image:view(1, 3, H, W))
      if opt.style_target_type == "guided_gram" then
        style_image_guides = image.scale(style_image_guides, W, H)
        style_image_guides = image.minmax {tensor = style_image_guides}
        percep_crit:setStyleTarget(
          {
            style_image:type(dtype),
            style_image_guides:view(1, n_guides, H, W):type(dtype)
          }
        )
      else
        percep_crit:setStyleTarget(style_image:type(dtype))
        if next(opt.histogram_layers) ~= nil then
          percep_crit:setHistTarget(style_image:type(dtype))
        end
      end
    end
  end

  -- Set up the depth loss function
  local depth_crit
  if opt.depth_loss_weight > 0 then
    local loss_net = torch.load(opt.depth_network) -- the model for depth_loss
    local crit_args = {
      cnn = loss_net,
      depth_layers = opt.depth_layers,
      depth_weights = opt.depth_weights
    }
    depth_crit = nn.DepthCriterion(crit_args):type(dtype)
  end

  -- Create dataloader
  local loader = DataLoader(opt)
  local params, grad_params = model:getParameters()

  local function shave_y(x, y, out)
    if opt.padding_type == "none" then
      local H, W = x:size(3), x:size(4)
      local HH, WW = out:size(3), out:size(4)
      local xs = (H - HH) / 2
      local ys = (W - WW) / 2
      return y[{{}, {}, {xs + 1, H - xs}, {ys + 1, W - ys}}]
    else
      return y
    end
  end

  ---------------------------------------
  -- Eval function
  ---------------------------------------
  local function f(x)
    assert(x == params)
    grad_params:zero()

    local x, y, g = loader:getBatch("train")
    x, y = x:type(dtype), y:type(dtype)
    target_for_display = preprocess.deprocess(y)

    -- Load guides from hdf5, dingyang add.
    local image_guides = nil
    if opt.style_target_type == "guided_gram" then
      local N, H, W = y:size(1), y:size(3), y:size(4)
      image_guides = image.scale(g[1]:double(), W, H):type(dtype)
      x = torch.cat(x, image_guides:view(1, n_guides, H, W):expand(N, n_guides, H, W), 2)
      y = {y, image_guides:view(1, n_guides, H, W):expand(N, n_guides, H, W)}
    end

    -- Run model forward
    local out = model:forward(x)
    local grad_out = nil

    -- This is a bit of a hack: if we are using reflect-start padding and the
    -- output is not the same size as the input, lazily add reflection padding
    -- to the start of the model so the input and output have the same size.
    if opt.padding_type == "reflect-start" and x:size(3) ~= out:size(3) then
      local ph = (x:size(3) - out:size(3)) / 2
      local pw = (x:size(4) - out:size(4)) / 2
      local pad_mod = nn.SpatialReflectionPadding(pw, pw, ph, ph):type(dtype)
      model:insert(pad_mod, 1)
      out = model:forward(x)
    end

    y = shave_y(x, y, out)

    if opt.style_target_type == "guided_gram" then
      local N, H, W = y[1]:size(1), y[1]:size(3), y[1]:size(4)
      out = {out, image_guides:view(1, n_guides, H, W):expand(N, n_guides, H, W)}
    end

    -- Compute pixel loss and gradient
    local pixel_loss = 0
    if pixel_crit then
      local pixel_loss = pixel_crit:forward(out, y)
      pixel_loss = pixel_loss * opt.pixel_loss_weight
      local grad_out_pix = pixel_crit:backward(out, y)
      if grad_out then
        grad_out:add(opt.pixel_loss_weight, grad_out_pix)
      else
        grad_out_pix:mul(opt.pixel_loss_weight)
        grad_out = grad_out_pix
      end
    end

    -- Compute perceptual loss and gradient
    local percep_loss = 0
    if percep_crit then
      local target = {content_target = y}
      percep_loss = percep_crit:forward(out, target)
      percep_loss = percep_loss * opt.percep_loss_weight
      local grad_out_percep = nil
      if opt.style_target_type == "guided_gram" then
        grad_out_percep = percep_crit:backward(out, target)[1]
      else
        grad_out_percep = percep_crit:backward(out, target)
      end
      if grad_out then
        grad_out:add(opt.percep_loss_weight, grad_out_percep)
      else
        grad_out_percep:mul(opt.percep_loss_weight)
        grad_out = grad_out_percep
      end
    end

    -- Compute depth loss and gradient
    local depth_loss = 0
    if depth_crit then
      local target = {content_target = y}
      depth_loss = depth_crit:forward(out, target) -- may need to edit target
      depth_loss = depth_loss * opt.depth_loss_weight
      local grad_out_depth = depth_crit:backward(out, target)
      if grad_out then
        grad_out:add(opt.depth_loss_weight, grad_out_depth)
      else
        grad_out_depth:mul(opt.depth_loss_weight)
        grad_out = grad_out_depth
      end
    end

    local loss = pixel_loss + percep_loss + depth_loss

    -- Run model backward
    model:backward(x, grad_out)

    -- Add regularization
    -- grad_params:add(opt.weight_decay, params)
    return loss, grad_params
  end

  ---------------------------------------
  -- Optimization
  ---------------------------------------
  local optim_state = {learningRate = opt.learning_rate}
  local train_loss_history = {}
  local val_loss_history = {}
  local val_loss_history_ts = {}
  local style_loss_history = {}
  local content_loss_history = {}
  local depth_loss_history = {}

  for t = 1, opt.num_iterations do
    -- Backpropogation
    local epoch = t / loader.num_minibatches["train"]
    local _, loss = optim.adam(f, params, optim_state)

    table.insert(train_loss_history, {t, loss[1]})

    local content_loss = 0
    local style_loss = 0
    local depth_loss = 0
    if opt.task == "style" then
      for i, k in ipairs(opt.style_layers) do
        style_loss = style_loss + percep_crit.style_losses[i]
      end
      for i, k in ipairs(opt.content_layers) do
        content_loss = content_loss + percep_crit.content_losses[i]
      end
      for i, k in ipairs(opt.depth_layers) do
        depth_loss = depth_loss + depth_crit.depth_losses[i]
      end
      table.insert(style_loss_history, {t, style_loss})
      table.insert(content_loss_history, {t, content_loss})
      table.insert(depth_loss_history, {t, depth_loss})
    end

    -- Print
    print(
      string.format(
        "Epoch %f, Iteration %d / %d, loss = %f, CLoss = %f, SLoss = %f, Dloss = %f",
        epoch,
        t,
        opt.num_iterations,
        loss[1],
        content_loss,
        style_loss,
        depth_loss
      ),
      optim_state.learningRate
    )

    -- Visualize
    if t % 50 == 0 then
      collectgarbage()
      local output = model.output:double()
      local imgs = {}
      local output = preprocess.deprocess(output)
      for i = 1, output:size(1) do
        table.insert(imgs, torch.clamp(output[i], 0, 1))
      end
      if use_display then
        display.image(target_for_display, {win = 1, width = 512, title = "Target"})
        display.image(imgs, {win = 0, width = 512, title = "Output"})
        display.plot(train_loss_history, {win = 2, labels = {"iteration", "Loss"}})
        display.plot(content_loss_history, {win = 2, labels = {"iteration", "Content Loss"}})
        display.plot(style_loss_history, {win = 2, labels = {"iteration", "Style Loss"}})
        display.plot(depth_loss_history, {win = 2, labels = {"iteration", "Depth Loss"}})
      end
    end

    -- Save checkpoint
    if t % opt.checkpoint_every == 0 then
      -- Check loss on the validation set
      loader:reset("val")
      model:evaluate()
      local val_loss = 0
      print "Running on validation set ... "
      local val_batches = opt.num_val_batches
      for j = 1, val_batches do
        local x, y = loader:getBatch("val")
        x, y = x:type(dtype), y:type(dtype)

        -- Same fixed guides for testing
        if opt.style_target_type == "guided_gram" then
          local N, H, W = y:size(1), y:size(3), y:size(4)
          -- Channels should be num_guides!!!
          image_guides = torch.zeros(3, 100, 100)
          image_guides[{{1}, {1, 30}, {}}] = 1
          image_guides[{{2}, {30, 60}, {}}] = 1
          image_guides[{{3}, {60, 100}, {}}] = 1
          image_guides = image.scale(image_guides:double(), W, H):type(dtype)
          x = torch.cat(x, image_guides:view(1, n_guides, H, W):expand(N, n_guides, H, W), 2)
          y = {y, image_guides:view(1, n_guides, H, W):expand(N, n_guides, H, W)}
        end

        local out = model:forward(x)
        y = shave_y(x, y, out)

        if opt.style_target_type == "guided_gram" then
          local N, H, W = y[1]:size(1), y[1]:size(3), y[1]:size(4)
          out = {out, image_guides:view(1, n_guides, H, W):expand(N, n_guides, H, W)}
        end

        local pixel_loss = 0
        if pixel_crit then
          pixel_loss = pixel_crit:forward(out, y)
          pixel_loss = opt.pixel_loss_weight * pixel_loss
        end
        local percep_loss = 0
        if percep_crit then
          percep_loss = percep_crit:forward(out, {content_target = y})
          percep_loss = opt.percep_loss_weight * percep_loss
        end
        val_loss = val_loss + pixel_loss + percep_loss
      end
      val_loss = val_loss / val_batches
      print(string.format("val loss = %f", val_loss))
      table.insert(val_loss_history, val_loss)
      table.insert(val_loss_history_ts, t)
      model:training()

      -- Save a JSON checkpoint
      local checkpoint = {
        opt = opt
        -- train_loss_history = train_loss_history,
        -- val_loss_history = val_loss_history,
        -- val_loss_history_ts = val_loss_history_ts,
        -- style_loss_history = style_loss_history
      }
      -- local filename = string.format("%s.json", opt.checkpoint_name)
      -- paths.mkdir(paths.dirname(filename))
      -- utils.write_json(filename, checkpoint)

      -- Save a torch checkpoint; convert the model to float first
      model:clearState()
      if use_cudnn then
        cudnn.convert(model, nn)
      end
      model:float()
      checkpoint.model = model
      filename = string.format("%s.t7", opt.checkpoint_name)
      torch.save(filename, checkpoint)

      -- Convert the model back
      model:type(dtype)
      if use_cudnn then
        cudnn.convert(model, cudnn)
      end
      params, grad_params = model:getParameters()
    end

    -- Decaying learning rate
    if opt.lr_decay_every > 0 and t % opt.lr_decay_every == 0 then
      local new_lr = opt.lr_decay_factor * optim_state.learningRate
      optim_state = {learningRate = new_lr}
    end
  end
end

main()
