# Binary Format: BPTF

This project introduces `.bptf`, an HRTF format using the RIFF container.

It is designed to be simple to parse, compact, and computationally inexpensive to apply in
real-time applications.

## Chunk Format

```
RIFF(BPTF)
│
├ "fmt "
│  └ version: u16 = 1
│
├ "geom"
│  ├ head_radius:  f32 (meters)
│  └ head_block:   f32 (meters)
│
└ LIST(info) - optional
   └ <arbitrary metadata chunks>
```

## Disambiguation

The encoded coordinate space uses:
+x = forward
+z = up
+y = left

The head and ear are assumed to be symmetrical under this format. To calculate
both channels of audio, apply the same pipeline but with the source direction
flipped about the y axis.

All distances are in meters, with a speed of sound of 343m/s

For information about the RIFF container format, see:
- [Wikipedia](https://en.wikipedia.org/wiki/Resource_Interchange_File_Format)
- [JohnLoomis.org](https://www.johnloomis.org/cpe102/asgn/asgn1/riff.html)

The code in this format description is a means to explain the math required.
It is not optimized or otherwise meant to be used without adaptation.

## Head Filter

### Delay (Romblom et al, 2019)

On the ipsilateral side (facing towards the source), the delay introduced by the head is computed 
as the free-field delay.  
On the contralateral side (facing away from the source), the delay introduced by the head 
is modeled as the perimeter of a semicircle attached to a rectangle.

The following code calculates the introduced delay in seconds:
```python
head_ear_pos = [0, ±head_radius, 0]

freefield_offset = dot(src_dir, head_ear_pos)
if freefield_offset > 0:
    head_delay = (
        - freefield_offset
        + head_radius # Prevents negative delay
    ) / speed_of_sound
else:
    theta = acos(freefield_offset / head_radius)
    contra_angle = theta - pi / 2
    arc_len = contra_angle * head_radius

    head_delay = (
        + arc_len # Distance around the circular portion
        + head_block * (1 - cos(contra_angle)) # Free-field compensated block perimeter
        + head_radius # Prevents negative delay
    ) / speed_of_sound
```

### Single-Pole Filter (Romblom et al, 2018)

The timbral changes introduced by diffraction around the head and torso 
are approximated with a single-pole recursive filter, depending on 
the radius of the occluding body and the angle between the source and observer:

```python
T = 1 / sample_rate
alpha = 0.3 + 0.85 * (1.0 - tanh(1.7 * (angle - 1.7)))

b_spread = head_radius / speed_of_sound * alpha
a_spread = head_radius / speed_of_sound

b = [T + b_spread, T - b_spread]
a = [T + a_spread, T - a_spread]

b /= a[0]
a /= a[0]
```
