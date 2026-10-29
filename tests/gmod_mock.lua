-- minimal gmod math mock (source engine conventions)
math.atan2 = math.atan2 or function(y,x) return math.atan(y,x) end
local V = {}; V.__index = V
function Vector(x, y, z)
  if type(x) == "table" then return setmetatable({x=x.x,y=x.y,z=x.z}, V) end
  return setmetatable({x=x or 0,y=y or 0,z=z or 0}, V)
end
isvector = function(v) return getmetatable(v) == V end
V.__add = function(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
V.__sub = function(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
V.__unm = function(a) return Vector(-a.x,-a.y,-a.z) end
V.__mul = function(a,b) if type(a)=="number" then a,b=b,a end return Vector(a.x*b,a.y*b,a.z*b) end
V.__div = function(a,b) return Vector(a.x/b,a.y/b,a.z/b) end
function V:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
function V:Cross(b) return Vector(self.y*b.z-self.z*b.y, self.z*b.x-self.x*b.z, self.x*b.y-self.y*b.x) end
function V:LengthSqr() return self:Dot(self) end
function V:Length() return math.sqrt(self:Dot(self)) end
function V:Length2D() return math.sqrt(self.x^2+self.y^2) end
function V:Distance(b) return (self-b):Length() end
function V:DistToSqr(b) return (self-b):LengthSqr() end
function V:GetNormalized() local l=self:Length(); return l>0 and self/l or Vector() end
function V:Normalize() local l=self:Length(); if l>0 then self.x,self.y,self.z=self.x/l,self.y/l,self.z/l end end
function V:Add(b) self.x,self.y,self.z=self.x+b.x,self.y+b.y,self.z+b.z end
vector_origin = Vector(0,0,0); vector_up = Vector(0,0,1)

local A = {}; A.__index = A
function Angle(p,y,r) if type(p)=="table" then return setmetatable({p=p.p,y=p.y,r=p.r},A) end return setmetatable({p=p or 0,y=y or 0,r=r or 0},A) end
isangle = function(a) return getmetatable(a) == A end
angle_zero = Angle()
local rad = math.rad
local function M(a) -- columns forward, left, up
  local sp,cp=math.sin(rad(a.p)),math.cos(rad(a.p))
  local sy,cy=math.sin(rad(a.y)),math.cos(rad(a.y))
  local sr,cr=math.sin(rad(a.r)),math.cos(rad(a.r))
  local f={cp*cy,cp*sy,-sp}
  local l={sr*sp*cy-cr*sy, sr*sp*sy+cr*cy, sr*cp}
  local u={cr*sp*cy+sr*sy, cr*sp*sy-sr*cy, cr*cp}
  return {{f[1],l[1],u[1]},{f[2],l[2],u[2]},{f[3],l[3],u[3]}}
end
local function mul(a,b) local c={{0,0,0},{0,0,0},{0,0,0}} for i=1,3 do for j=1,3 do for k=1,3 do c[i][j]=c[i][j]+a[i][k]*b[k][j] end end end return c end
local function T(a) local c={{0,0,0},{0,0,0},{0,0,0}} for i=1,3 do for j=1,3 do c[i][j]=a[j][i] end end return c end
local function mv(m,v) return Vector(m[1][1]*v.x+m[1][2]*v.y+m[1][3]*v.z, m[2][1]*v.x+m[2][2]*v.y+m[2][3]*v.z, m[3][1]*v.x+m[3][2]*v.y+m[3][3]*v.z) end
local function toAng(m)
  local f={m[1][1],m[2][1],m[3][1]}; local l={m[1][2],m[2][2],m[3][2]}; local u={m[1][3],m[2][3],m[3][3]}
  local xy=math.sqrt(f[1]^2+f[2]^2)
  if xy>0.001 then return Angle(math.deg(math.atan(-f[3],xy)), math.deg(math.atan(f[2],f[1])), math.deg(math.atan(l[3],u[3])))
  else return Angle(math.deg(math.atan(-f[3],xy)), math.deg(math.atan(-l[1],l[2])), 0) end
end
local function axisRot(ax, deg)
  local a=ax:GetNormalized(); local c,s=math.cos(rad(deg)),math.sin(rad(deg)); local t=1-c
  local x,y,z=a.x,a.y,a.z
  return {{t*x*x+c, t*x*y-s*z, t*x*z+s*y},{t*x*y+s*z, t*y*y+c, t*y*z-s*x},{t*x*z-s*y, t*y*z+s*x, t*z*z+c}}
end
MOCK = {M=M, mul=mul, T=T, mv=mv, toAng=toAng}
function A:Forward() local m=M(self) return Vector(m[1][1],m[2][1],m[3][1]) end
function A:Right() local m=M(self) return Vector(-m[1][2],-m[2][2],-m[3][2]) end
function A:Up() local m=M(self) return Vector(m[1][3],m[2][3],m[3][3]) end
function A:RotateAroundAxis(ax, deg) local n=toAng(mul(axisRot(ax,deg), M(self))); self.p,self.y,self.r=n.p,n.y,n.r end
function V:Rotate(a) local r=mv(M(a), self); self.x,self.y,self.z=r.x,r.y,r.z end
function WorldToLocal(pos, ang, o, oa) local mt=T(M(oa)); return mv(mt, pos-o), toAng(mul(mt, M(ang))) end
function LocalToWorld(lp, la, o, oa) local m=M(oa); return o+mv(m,lp), toAng(mul(m, M(la))) end
math.Clamp = function(v,a,b) return math.min(math.max(v,a),b) end
function Lerp(t,a,b) return a+(b-a)*t end
math.AngleDifference = function(a,b) local d=(a-b+180)%360-180 return d end
function LerpAngle(t,a,b) return Angle(a.p+math.AngleDifference(b.p,a.p)*t, a.y+math.AngleDifference(b.y,a.y)*t, a.r+math.AngleDifference(b.r,a.r)*t) end
isnumber = function(v) return type(v)=="number" end
isbool = function(v) return type(v)=="boolean" end
SERVER = false; CLIENT = true
IKFoot = { Config = {}, Runtime = {} }
