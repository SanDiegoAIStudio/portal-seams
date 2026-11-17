# portal-seams

A recipe for chaining image-to-video clips when the video model does not hold the first frame of the image you give it: end each clip in an even glow wash, hand the actual final frame of the encoded clip to the next clip, and open that clip from the same wash. `seam-check.sh` scores each seam with SSIM so you can see which clip to re-roll.

## Quick start

Score the seam between two clips (the end of the first against the start of the second):

```sh
sh seam-check.sh clip-1.mp4 clip-2.mp4
```

Score a conditioning image against the first frame of the clip made from it:

```sh
sh seam-check.sh still.png clip-1.mp4
```

Each run prints one line, such as `seam ssim 0.975 PASS (threshold 0.90)`, and exits 0 on a pass and 1 on a fail.

## The technique

Some image-to-video models do not continue from your pixels. They take the conditioning image as a hint and re-render the scene in their own way, so the first frame of the clip does not match the image. Chain two clips by handing the last frame of one to the next and the join shows as a jump cut.

The fix is to make every handoff frame carry almost no information. A re-render of a glow wash is still a glow wash, so the model has nothing to diverge from.

1. End each clip in the wash. Prompt the clip to finish with something like: "pushing into a glowing doorway until soft warm amber light completely fills the frame (even wash, no visible detail)".
2. Hand off the real last frame. Extract the final frame of the encoded clip, not of the model's raw output. That frame is the conditioning image for the next clip.
3. Open the next clip from the same wash. Prompt it to begin with something like: "the frame begins completely filled with a soft even wash of glowing warm amber light, the glow gently recedes and parts, revealing ..." and describe the next scene.

Pick the wash color from your project palette and the glow doubles as a transition between scenes.

## The seam gate

`seam-check.sh A B [--threshold T]` scores one seam.

- A is a video clip or a still image (png, jpg, jpeg or webp, judged by the file extension). B is a video clip.
- The frame from A is the frame 0.05 seconds before the end of the clip, or the image itself. The frame from B is its first frame. Measure on the encoded clips you will ship, because encoding changes frames.
- Keep to 0.05 seconds. Sampling earlier, for example 0.15 seconds before the end, lands while the clip is still easing into the wash and scores the same seam differently, so scores stop being comparable.
- When the clip frame rate is so low that no frame falls in the last 0.05 seconds, the script takes the last frame there is and prints a note.
- When the two frames differ in size, the frame from B is scaled to the size of the frame from A and a note says so.
- Both frames are converted to yuv420p, the format clips are normally encoded in, and scored with ffmpeg's `ssim` filter. The script reads the `All:` value and prints it with three decimals. Scored as RGB the same pair reads lower, so the pass line only means something against one fixed format.
- The default pass line is 0.90. Set another with `--threshold`. A score equal to the pass line passes.
- Exit codes: 0 pass, 1 fail, 2 for a usage error, a missing file, ffmpeg not found, or a frame that could not be read.
- Fail means re-roll the failing clip only. The wash ending makes that cheap: the clips before and after it are untouched.

## Example

`tests/test.sh` makes its own clips with ffmpeg's `lavfi` sources: clip A is a test pattern that ends in a solid amber second, clip B opens on amber, and a third clip opens on the test pattern. These lines are from a run of `sh tests/test.sh`:

```
ok   [sh] 1 amber to amber passes :: seam ssim 1.000 PASS (threshold 0.90)
ok   [sh] 2 amber to test pattern fails :: seam ssim 0.348 FAIL (threshold 0.90)
ok   [sh] 3 png still to clip passes :: seam ssim 1.000 PASS (threshold 0.90)
ok   [sh] 3c png still to test pattern fails :: seam ssim 0.348 FAIL (threshold 0.90)
ok   [sh] 4 different sizes prints the scale note :: seam ssim 1.000 PASS (threshold 0.90)
test.sh: all cases passed under: sh bash zsh
```

`sh tests/mutate.sh` breaks a copy of the script in 14 ways, one at a time (wrong sample point, ignored threshold, flipped comparison, dropped scaling, changed exit codes and others), and checks that `tests/test.sh` turns red for each. In the run for this README, 14 of 14 were killed.

## Measured on a real film

Measured with `seam-check.sh` on the four encoded clips of a short scroll film the author made with an image-to-video model that does not hold the first frame, the three seams between the clips scored:

| Seam | Score | Result at 0.90 |
|---|---|---|
| clip 1 to clip 2 | 0.975 | PASS |
| clip 2 to clip 3 | 0.932 | PASS |
| clip 3 to clip 4 | 0.982 | PASS |

The frame-lock check, the conditioning still of the first scene against the first frame of the clip generated from it (the generated clip, before the film was encoded), scored 0.537 and failed. The still was 3:2 and the clip 16:9, so the script stretched the clip frame to the still's size before scoring. That is the reason for the technique: the model re-rendered the scene instead of continuing from the still.

A plain chained handoff on the same film, with no wash, showed a visible jump cut. That clip was not kept, so it is not scored here.

## When to use it

| Model behavior | Handoff to use |
|---|---|
| Does not hold the first frame of its conditioning image | Portal seams and the gate |
| Holds the first frame | A plain last-frame handoff, which puts no glow constraint on the art |

Check before assuming. Make one clip from a detailed conditioning image and score its first frame against that image:

```sh
sh seam-check.sh still.png clip-1.mp4
```

A score at or above your pass line suggests the model holds the first frame. A score far below it, like the 0.537 above, means it does not, and you need the technique. Check each model, because behavior differs between them.

## Needs

- ffmpeg with the `ssim` filter, and ffprobe. Tested with ffmpeg 9.0.2 on macOS.
- A POSIX shell. The tests run the script under `sh`, `bash` and `zsh` when they exist.

No install step. Nothing is downloaded.

## Limits

- SSIM measures the structural similarity of two frames. It does not measure motion, and it does not measure whether the color and light carry over across the cut in a way the eye accepts.
- The glow wash constrains the art at every seam: each scene must begin and end in the wash, so the picture at the join is always the same kind of frame.
- The gate cannot judge whether the shot is good, only whether the join is clean.
- A still image is judged by file extension. A file named anything else is treated as a clip and must have a duration.
- When a still and a clip have different aspect ratios, the clip frame is stretched to the still's size. Match the aspect ratios first if you want a score you can compare.

## License

MIT. See `LICENSE`.

## Built at San Diego AI Studio

This recipe comes out of San Diego AI Studio, the builders' community in San Diego. Projects from the Studio are listed at https://sandiegoaistudio.com/projects
