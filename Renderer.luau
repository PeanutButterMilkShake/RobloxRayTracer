-- Credit: Discord Username: rolypoly4107 | Roblox Username: YourRobloxName

local Renderer = {}
Renderer.__index = Renderer

-- Roblox Engine Service Accessors
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local WorkspaceService = game:GetService("Workspace")

-- Type definitions for strict Luau analysis compliance
type RaycastMap = { [BasePart]: RaycastParams }
type ColorGrid = { [number]: { [number]: Color3 } }

-- Static Engine Constants Configuration
local MAX_RAY_DISTANCE: number = 1000
local SKY_COLOR_VEC: Vector3 = Vector3.new(0.592157, 0.776471, 1)
local SUN_COLOR: Vector3 = Vector3.new(1, 1, 1)
local SUN_DIRECTION: Vector3 = Vector3.new(0.5, 0.5, 0).Unit
local AMBIENT_COLOR: Vector3 = Vector3.new(0.1, 0.1, 0.15)

-- Core Quality Settings
local GI_SAMPLES: number = 4
local GI_STRENGTH: number = 0.3
local MAX_BOUNCES: number = 6 
local YIELD_EVERY: number = 500

-- Denoising (Bilateral Spatial-Chromatic Kernel) Config
local ENABLE_DENOISER: boolean = true
local FILTER_RADIUS: number = 2    
local SIGMA_SPACE: number = 2.0    
local SIGMA_COLOR: number = 0.15   

-- Internal Module Cache to eliminate garbage collection pressure
local vectorCache: { [Color3]: Vector3 } = {}
local colorCache: { [Vector3]: Color3 } = {}

-- Precomputed Spatial Filter Grid Matrix to optimize post-processing
local SPATIAL_WEIGHTS: { [number]: { [number]: number } } = {}
do
	for ky = -FILTER_RADIUS, FILTER_RADIUS do
		SPATIAL_WEIGHTS[ky] = {}
		for kx = -FILTER_RADIUS, FILTER_RADIUS do
			local distSq = (kx * kx) + (ky * ky)
			SPATIAL_WEIGHTS[ky][kx] = math.exp(-distSq / (2 * SIGMA_SPACE * SIGMA_SPACE))
		end
	end
end

-- Fast Type-Conversion Layer with Localized Memory Caching
local function VectorToColor(vector: Vector3): Color3
	local cached = colorCache[vector]
	if cached then return cached end

	local res = Color3.new(
		math.clamp(vector.X, 0, 1),
		math.clamp(vector.Y, 0, 1),
		math.clamp(vector.Z, 0, 1)
	)
	colorCache[vector] = res
	return res
end

local function ColorToVector(color: Color3): Vector3
	local cached = vectorCache[color]
	if cached then return cached end

	local res = Vector3.new(color.R, color.G, color.B)
	vectorCache[color] = res
	return res
end

-- Math Layer: Local Space Coordinate Transformation Matrices
local function GetLocalFrame(normal: Vector3): (Vector3, Vector3)
	local tangent: Vector3
	if math.abs(normal.X) < 0.9 then
		tangent = normal:Cross(Vector3.new(1, 0, 0)).Unit
	else
		tangent = normal:Cross(Vector3.new(0, 1, 0)).Unit
	end
	local bitangent: Vector3 = normal:Cross(tangent)
	return tangent, bitangent
end

-- Mathematical Raycasting Utilities
local function ShadowRaycast(origin: Vector3, direction: Vector3, params: RaycastParams): boolean
	local result = WorkspaceService:Raycast(origin, direction, params)
	return result == nil
end

local function RandomHemisphereDir(normal: Vector3): Vector3
	local u1: number = math.random()
	local u2: number = math.random()
	local r: number = math.sqrt(u1)
	local theta: number = 2 * math.pi * u2

	local x: number = r * math.cos(theta)
	local z: number = math.sqrt(1 - u1)
	local y: number = r * math.sin(theta)

	local tangent, bitangent = GetLocalFrame(normal)
	return (tangent * x + normal * z + bitangent * y).Unit
end

local function RoughReflectDir(reflectDir: Vector3, normal: Vector3, roughness: number): Vector3
	if roughness < 0.02 then return reflectDir end
	if roughness > 0.98 then return RandomHemisphereDir(normal) end

	local alpha: number = roughness * roughness
	local u1: number = math.random()
	local u2: number = math.random()

	local tanTheta2: number = alpha * alpha * (u1 / (1 - u1 + 1e-6))
	local cosTheta: number = 1 / math.sqrt(1 + tanTheta2)
	local sinTheta: number = math.sqrt(math.max(0, 1 - cosTheta * cosTheta))
	local phi: number = 2 * math.pi * u2

	local pX: number = sinTheta * math.cos(phi)
	local pZ: number = sinTheta * math.sin(phi)
	local pY: number = cosTheta

	local tangent, bitangent = GetLocalFrame(reflectDir)
	local perturbed: Vector3 = (tangent * pX + bitangent * pZ + reflectDir * pY).Unit

	if perturbed:Dot(normal) < 0 then
		perturbed = (perturbed - normal * 2 * perturbed:Dot(normal)).Unit
	end

	return perturbed
end

-- Dynamic Global Illumination and Environment Sampling
local function SampleIndirectLight(origin: Vector3, normal: Vector3, params: RaycastParams): Vector3
	local indirect: Vector3 = Vector3.new(0, 0, 0)
	local tangent, bitangent = GetLocalFrame(normal)

	for i = 1, GI_SAMPLES do
		local u1: number = (i + math.random()) / GI_SAMPLES
		local u2: number = math.random()
		local r: number = math.sqrt(u1)
		local theta: number = 2 * math.pi * u2

		local x: number = r * math.cos(theta)
		local z: number = math.sqrt(1 - u1)
		local y: number = r * math.sin(theta)

		local dir: Vector3 = (tangent * x + normal * z + bitangent * y).Unit
		local result = WorkspaceService:Raycast(origin, dir * MAX_RAY_DISTANCE, params)

		if result then
			if result.Instance.Material == Enum.Material.Neon then
				indirect += ColorToVector(result.Instance.Color)
			else
				local albedo: Vector3 = ColorToVector(result.Instance.Color)
				local nDotL: number = math.max(0, result.Normal:Dot(SUN_DIRECTION))
				indirect += albedo * (SUN_COLOR * nDotL * 0.5 + AMBIENT_COLOR)
			end
		else
			indirect += SKY_COLOR_VEC
		end
	end
	return indirect / GI_SAMPLES
end

-- Physically Based Rendering Point Shading Evaluation
local function ShadePoint(
	hitResult: RaycastResult, 
	rayDirection: Vector3, 
	neonParts: {BasePart}, 
	neonParams: RaycastMap, 
	sunParams: RaycastParams, 
	currentBounce: number
): (Vector3, Vector3, Vector3?, Vector3?, Vector3?)
	local albedo: Vector3 = ColorToVector(hitResult.Instance.Color)

	if hitResult.Instance.Material == Enum.Material.Neon then
		return albedo, Vector3.new(0, 0, 0), nil, nil, Vector3.new(0, 0, 0)
	end

	local metalness: number = hitResult.Instance.Reflectance
	local roughness: number = hitResult.Instance:GetAttribute("roughness") 
		or hitResult.Instance:GetAttribute("Roughness")
		or (hitResult.Instance.Material == Enum.Material.SmoothPlastic and 0.05 or 0.5)

	local offsetOrigin: Vector3 = hitResult.Position + hitResult.Normal * 0.001
	local viewDir: Vector3 = (-rayDirection).Unit
	local reflectDir: Vector3 = (rayDirection - hitResult.Normal * 2 * rayDirection:Dot(hitResult.Normal)).Unit

	local F0: Vector3 = metalness > 0.1 and albedo or Vector3.new(0.04, 0.04, 0.04)
	local cosTheta: number = math.max(0, viewDir:Dot(hitResult.Normal))
	local fresnel: Vector3 = F0 + (Vector3.new(1, 1, 1) - F0) * (1 - cosTheta) ^ 5

	local diffuseWeight: Vector3 = (Vector3.new(1, 1, 1) - fresnel) * (1 - metalness)
	local specularWeight: Vector3 = fresnel + (Vector3.new(1, 1, 1) - fresnel) * metalness

	local color: Vector3 = albedo * AMBIENT_COLOR * diffuseWeight
	local sunDot: number = math.max(0, hitResult.Normal:Dot(SUN_DIRECTION))

	if sunDot > 0 and ShadowRaycast(offsetOrigin, SUN_DIRECTION * MAX_RAY_DISTANCE, sunParams) then
		color += albedo * SUN_COLOR * sunDot * diffuseWeight
	end

	for i = 1, #neonParts do
		local part = neonParts[i]
		local toLight: Vector3 = part.Position - hitResult.Position
		local distance: number = toLight.Magnitude
		local lightDir: Vector3 = toLight.Unit
		local diffuse: number = math.max(0, hitResult.Normal:Dot(lightDir))

		if diffuse > 0 and ShadowRaycast(offsetOrigin, lightDir * distance, neonParams[part]) then
			local attenuation: number = 1 / (1 + distance * 0.1)
			color += albedo * ColorToVector(part.Color) * diffuse * attenuation * 5 * diffuseWeight
		end
	end

	if currentBounce >= MAX_BOUNCES then
		return color, diffuseWeight, nil, nil, Vector3.new(0, 0, 0)
	end

	local nextRayDir: Vector3 = (roughness < 0.02) and reflectDir or RoughReflectDir(reflectDir, hitResult.Normal, roughness)
	return color, diffuseWeight, offsetOrigin, nextRayDir, specularWeight
end

-- Public Object Constructor (Metatable Verification Pattern)
function Renderer.new(targetGui: ScreenGui, pixelStep: number)
	local self = setmetatable({}, Renderer)

	self.camera = WorkspaceService.CurrentCamera
	self.gui = targetGui
	self.loadingText = targetGui.LoadingScreen.TextLabel.TextLabel
	self.pixelStep = pixelStep or 2
	self.skyColor = Color3.new(0.592157, 0.776471, 1)

	return self
end

-- Main Processing Engine Routine
function Renderer:RenderFrame(): ColorGrid
	self.gui.Enabled = true

	local resolution: Vector2 = Vector2.new(
		math.floor(self.camera.ViewportSize.X / self.pixelStep),
		math.floor(self.camera.ViewportSize.Y / self.pixelStep)
	)

	local neonParts: {BasePart} = {}
	local neonParams: RaycastMap = {}
	local descendants: {Instance} = WorkspaceService:GetDescendants()

	for i = 1, #descendants do
		local desc = descendants[i]
		if desc:IsA("BasePart") and desc.Material == Enum.Material.Neon then
			table.insert(neonParts, desc)
			local p = RaycastParams.new()
			p.FilterDescendantsInstances = {desc}
			p.FilterType = Enum.RaycastFilterType.Exclude
			neonParams[desc] = p
		end
	end

	local sunParams: RaycastParams = RaycastParams.new()
	sunParams.FilterType = Enum.RaycastFilterType.Exclude
	sunParams.FilterDescendantsInstances = {}

	local defaultParams: RaycastParams = RaycastParams.new()
	local renderOutput: ColorGrid = {}

	local totalPixels: number = resolution.X * resolution.Y
	local currentPixel: number = 0

	-- Primary Interleaved Raytracing Execution Loop
	for outY = 1, resolution.Y do
		renderOutput[outY] = {}
		local screenY: number = ((outY - 1) * self.pixelStep) + 1

		for outX = 1, resolution.X do
			local screenX: number = ((outX - 1) * self.pixelStep) + 1
			currentPixel += 1

			if currentPixel % YIELD_EVERY == 0 then
				task.wait()
			end

			local ray: Ray = self.camera:ViewportPointToRay(screenX, screenY)
			local rayDir: Vector3 = ray.Direction.Unit
			local result: RaycastResult? = WorkspaceService:Raycast(ray.Origin, rayDir * MAX_RAY_DISTANCE)

			if result then
				local currentResult: RaycastResult = result
				local currentRayDir: Vector3 = rayDir
				local accumulatedColor: Vector3 = Vector3.new(0, 0, 0)
				local throughput: Vector3 = Vector3.new(1, 1, 1)

				for bounce = 1, MAX_BOUNCES do
					local localColor, diffuseWeight, nextOrigin, nextDir, specularWeight = ShadePoint(
						currentResult, 
						currentRayDir, 
						neonParts, 
						neonParams, 
						sunParams, 
						bounce
					)

					accumulatedColor += localColor * throughput

					if bounce == 1 then
						local offsetOrigin = currentResult.Position + currentResult.Normal * 0.01
						local indirect = SampleIndirectLight(offsetOrigin, currentResult.Normal, defaultParams)
						accumulatedColor += ColorToVector(currentResult.Instance.Color) * indirect * GI_STRENGTH * diffuseWeight
					end

					if not nextOrigin or not nextDir then
						break
					end

					local reflectParams = RaycastParams.new()
					reflectParams.FilterType = Enum.RaycastFilterType.Exclude
					reflectParams.FilterDescendantsInstances = {currentResult.Instance}

					local nextResult = WorkspaceService:Raycast(nextOrigin, nextDir * MAX_RAY_DISTANCE, reflectParams)

					if nextResult then
						throughput = throughput * specularWeight
						currentResult = nextResult
						currentRayDir = nextDir
					else
						accumulatedColor += SKY_COLOR_VEC * throughput * specularWeight
						break
					end
				end

				renderOutput[outY][outX] = VectorToColor(accumulatedColor)
			else
				renderOutput[outY][outX] = self.skyColor
				-- Process end boundary bounds safely
			end
		end
		self.loadingText.Text = "Rendering Stage: " .. math.floor((currentPixel / totalPixels) * 100) .. "%"
	end

	-- Bilateral Denoising Filter Routine Stage
	if ENABLE_DENOISER then
		self.loadingText.Text = "Executing Spatial Denoising Engine..."
		local denoisedOutput: ColorGrid = {}

		for y = 1, resolution.Y do
			denoisedOutput[y] = {}
			for x = 1, resolution.X do
				local centerColor: Color3 = renderOutput[y][x]
				local rSum, gSum, bSum, weightSum = 0, 0, 0, 0

				for ky = -FILTER_RADIUS, FILTER_RADIUS do
					local sampleY = y + ky
					if sampleY >= 1 and sampleY <= resolution.Y then
						for kx = -FILTER_RADIUS, FILTER_RADIUS do
							local sampleX = x + kx
							if sampleX >= 1 and sampleX <= resolution.X then
								local sampleColor: Color3 = renderOutput[sampleY][sampleX]

								local rDiff = sampleColor.R - centerColor.R
								local gDiff = sampleColor.G - centerColor.G
								local bDiff = sampleColor.B - centerColor.B
								local colorDistSq = (rDiff * rDiff) + (gDiff * gDiff) + (bDiff * bDiff)

								local colorWeight = math.exp(-colorDistSq / (2 * SIGMA_COLOR * SIGMA_COLOR))
								local totalWeight = SPATIAL_WEIGHTS[ky][kx] * colorWeight

								rSum += sampleColor.R * totalWeight
								gSum += sampleColor.G * totalWeight
								bSum += sampleColor.B * totalWeight
								weightSum += totalWeight
							end
						end
					end
				end

				denoisedOutput[y][x] = Color3.new(rSum / weightSum, gSum / weightSum, bSum / weightSum)
			end

			if y % 40 == 0 then
				task.wait()
			end
		end
		renderOutput = denoisedOutput
	end

	self.loadingText.Text = "Frame Completion Successful"
	return renderOutput
end

return Renderer
