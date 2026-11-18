#!/usr/bin/env python3
"""Writes analysis/motion_quality.ipynb (rep counter, Stage B step 5). Kept as a script so the
notebook's source is reviewable in a diff; run the notebook itself with

    jupyter nbconvert --to html --execute analysis/motion_quality.ipynb --output-dir data/reports

Outputs hold the user's motion data: they go to data/reports (git-ignored), never into git.
"""
import nbformat as nbf

cells = [
    ("md", """# Motion data quality (rep counter, Stage B)

Is the watch's motion data good enough to learn a rep counter from? Reads the labels from
`analysis/motion_check.py` (`data/motion-labels.csv`) and the CSVs in `data/motion-phone` and
`data/motion`. One person, one wrist, a few exercises: nothing here generalises beyond that."""),
    ("code", """import glob, json, os
import numpy as np, pandas as pd, matplotlib.pyplot as plt

ROOT = '..' if os.path.basename(os.getcwd()) == 'analysis' else '.'
lab = pd.read_csv(f'{ROOT}/data/motion-labels.csv')
paths = {os.path.basename(p): p for d in ('data/motion-phone', 'data/motion')
         for p in glob.glob(f'{ROOT}/{d}/**/*.csv', recursive=True)}
# One English name per exercise id (the app wrote some names as "中文 (English)").
eng = lab['name'].where(lab['name'].map(str.isascii), lab['name'].str.split(' (', n=1, regex=False).str[1].str[:-1])
lab['short'] = lab['exId'].map(eng.groupby(lab['exId']).first())
clean = lab[lab['flags'].isna()].copy()
print(len(lab), 'labelled sets,', len(clean), 'without flags')"""),
    ("md", "## 1. What there is"),
    ("code", """pd.crosstab(clean['short'], clean['date']).assign(total=lambda d: d.sum(axis=1)).sort_values('total', ascending=False)"""),
    ("code", """lab['flags'].fillna('none').str.split('; ').explode().value_counts()"""),
    ("md", "## 2. Sampling: 50 Hz, no gaps?"),
    ("code", """fig, ax = plt.subplots(1, 2, figsize=(11, 3.2))
lab['hz'].plot.hist(bins=30, ax=ax[0], title='sample rate per set (Hz)')
ax[1].scatter(pd.to_datetime(lab['date'].astype(str)), lab['max_gap_s'], s=12)
ax[1].set_yscale('log'); ax[1].axhline(0.1, color='r', lw=0.8)
ax[1].set_title('largest gap per set (s, red: flag at 0.1 s)')
plt.tight_layout()"""),
    ("md", """## 3. Does the window hold the whole set?

`head` / `tail`: how busy the first / last second is, against the set's 90th-percentile activity.
A busy start with no rep in the first 2 s is the walk to the machine; a busy end would be a set cut
before it finished."""),
    ("code", """fig, ax = plt.subplots(1, 2, figsize=(11, 3.2))
lab['head'].plot.hist(bins=30, ax=ax[0], title='activity in the first second / set activity')
lab['tail'].plot.hist(bins=30, ax=ax[1], title='activity in the last second / set activity')
for a in ax: a.axvline(0.6, color='r', lw=0.8)
plt.tight_layout()"""),
    ("md", "## 4. One set per exercise\n\nUser acceleration (g) and its smoothed magnitude; ticks: reps the watch counted live."),
    ("code", """def load(f):
    with open(paths[f]) as h:
        meta = json.loads(h.readline()[2:])
    return meta, pd.read_csv(paths[f], skiprows=1)

examples = clean.sort_values('date').groupby('exId').tail(1)
n = len(examples)
fig, axes = plt.subplots(n, 1, figsize=(11, 2.0 * n), sharex=False)
for ax, (_, r) in zip(np.atleast_1d(axes), examples.iterrows()):
    meta, d = load(r['file'])
    for c in ('ax', 'ay', 'az'):
        ax.plot(d['t'], d[c], lw=0.5, label=c)
    ax.plot(d['t'], np.sqrt(d.ax**2 + d.ay**2 + d.az**2).rolling(25, center=True).mean(), 'k', lw=1)
    for t, what in meta.get('helpers', {}).get('log', []):
        if isinstance(what, str) and what.startswith('rep '):
            ax.axvline(t, color='grey', lw=0.5, ls=':')
    ax.set_title(f"{r['short']}: {r['reps']:.0f} reps logged, {r['watch_auto']} counted live", fontsize=9)
plt.tight_layout()"""),
    ("md", """## 5. Baseline for Stage D: the watch's live count

What the counter on the watch gets today, per exercise, against the logged reps (the label).
Stage D has to beat this. (A rhythm count from acceleration was tried and dropped here: the wrist's
acceleration often has two peaks per rep, so a frequency count doubles; that belongs to Stage D.)"""),
    ("code", """live = clean.dropna(subset=['watch_auto']).copy()
live['err'] = (live['watch_auto'] - live['reps']).abs()
live['exact'] = live['err'] == 0
(live.groupby('short').agg(sets=('file', 'size'), reps=('reps', 'mean'), mae=('err', 'mean'),
                           exact=('exact', 'mean'), bias=('watch_auto', 'mean'))
     .assign(bias=lambda d: d['bias'] - d['reps']).round(2).sort_values('sets', ascending=False))"""),
    ("code", """fig, ax = plt.subplots(figsize=(5, 4.5))
ax.scatter(live['reps'], live['watch_auto'], s=14, alpha=0.7)
m = live[['reps', 'watch_auto']].to_numpy().max()
ax.plot([0, m], [0, m], 'k', lw=0.6)
ax.set_xlabel('logged reps'); ax.set_ylabel('live count on the watch')
print(len(live), 'sets | MAE', round(live['err'].mean(), 2), '| exact', f"{live['exact'].mean():.0%}",
      '| bias', round((live['watch_auto'] - live['reps']).mean(), 2))"""),
    ("md", """## 6. Findings

Written up in the report to the user (2026-11-18): see the cell outputs above for the numbers.
Re-run after each pull (`analysis/pull_motion.sh`) to see the data grow."""),
]

nb = nbf.v4.new_notebook()
nb.cells = [nbf.v4.new_markdown_cell(s) if k == "md" else nbf.v4.new_code_cell(s) for k, s in cells]
nb.metadata["kernelspec"] = {"name": "python3", "display_name": "Python 3", "language": "python"}
nbf.write(nb, "analysis/motion_quality.ipynb")
print("wrote analysis/motion_quality.ipynb")
