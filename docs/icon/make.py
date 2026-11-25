"""Generates the Spool app icon (Big Reel with a play button).

Run from the repo root:  python3 docs/icon/make.py
Writes Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png (iOS),
Sources/Mac/KasetMacIcon.icon/Assets/{Reel,Play}.png (macOS Icon Composer layers)
AppIcon-Dark.png (iOS dark appearance) and docs/icon/AppIcon-rounded.png (README).
Needs Pillow.
"""
import math
from PIL import Image, ImageDraw, ImageFilter
S=4; N=1024*S
BLUE=(19,96,252,255)
C=600*S; R=540*S
def pt(cx,cy,r,deg): a=math.radians(deg); return cx+r*math.cos(a), cy+r*math.sin(a)
def circle(d,cx,cy,r,fill): d.ellipse([cx-r,cy-r,cx+r,cy+r],fill=fill)
def tri(cx,cy,h):
    w=h*0.9; return [(cx-w/3,cy-h/2),(cx-w/3,cy+h/2),(cx+2*w/3,cy)]
def rounded_tri(d,pts,stroke,fill):
    d.polygon(pts,fill=fill)
    d.line(pts+[pts[0]],fill=fill,width=stroke,joint="curve")
    for x,y in pts: circle(d,x,y,stroke/2,fill)

def reel_layer():
    im=Image.new("RGBA",(N,N),(0,0,0,0)); d=ImageDraw.Draw(im)
    circle(d,C,C,R,BLUE)
    for i in range(3):
        x,y=pt(C,C,300*S,-100+i*120); circle(d,x,y,150*S,(0,0,0,0))
    circle(d,C,C,112*S,(0,0,0,0))
    return im
def play_layer():
    im=Image.new("RGBA",(N,N),(0,0,0,0)); d=ImageDraw.Draw(im)
    rounded_tri(d,tri(C+6*S,C,92*S),26*S,BLUE)
    return im
def down(im): return im.resize((1024,1024),Image.LANCZOS)

reel=down(reel_layer()); play=down(play_layer())
reel.save("Sources/Mac/KasetMacIcon.icon/Assets/Reel.png"); play.save("Sources/Mac/KasetMacIcon.icon/Assets/Play.png")

def gradient(top,bot):
    im=Image.new("RGBA",(1024,1024))
    for y in range(1024):
        t=y/1023; c=tuple(round(top[i]*(1-t)+bot[i]*t) for i in range(3))
        ImageDraw.Draw(im).line([(0,y),(1023,y)],fill=c+(255,))
    return im

# iOS: light gradient like the current icon, soft shadow under the glyph
bg=gradient((249,249,251),(234,234,237))
glyph=Image.alpha_composite(reel,play)
sh=Image.new("RGBA",(1024,1024),(0,0,0,0))
sh.paste((20,40,90,70),(0,0,1024,1024),glyph.split()[3])
sh=sh.filter(ImageFilter.GaussianBlur(28))
bg.alpha_composite(glyph)
bg.convert("RGB").save("Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

# iOS dark appearance: same glyph on the system's dark gray gradient
dark=gradient((44,44,46),(22,22,24))
dark.alpha_composite(glyph)
dark.convert("RGB").save("Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png")

# README: the iOS icon with the system's rounded corners
r=bg.resize((512,512),Image.LANCZOS)
m=Image.new("L",(512,512),0); ImageDraw.Draw(m).rounded_rectangle([0,0,511,511],115,fill=255)
r.putalpha(m); r.save("docs/icon/AppIcon-rounded.png")

