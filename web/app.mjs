import {moontile_plan, moontile_process} from './moontile.mjs';

const el = id => document.querySelector(`#${id}`);
const input = el('input'), canvas = el('canvas'), report = el('report'), mergeStatus = el('merge-status');
const planCanvas = el('plan-canvas'), planStatus = el('plan-status'), usePlan = el('use-plan');
const fields = ['image-width', 'image-height', 'tile-width', 'tile-height', 'overlap-x', 'overlap-y'];
let currentPlan = null;

input.value = JSON.stringify({image_width:100,image_height:60,threshold:.5,metric:'ios',class_agnostic:false,strategy:'greedy_nmm',tiles:[{tile:{id:0,x:0,y:0,width:60,height:60},detections:[{id:1,image_id:1,tile_id:0,class_id:0,score:.95,box:{x1:45,y1:10,x2:60,y2:30}}]},{tile:{id:1,x:40,y:0,width:60,height:60},detections:[{id:2,image_id:1,tile_id:1,class_id:0,score:.85,box:{x1:10,y1:10,x2:30,y2:30}}]}]}, null, 2);

function rect(svg, x, y, width, height, cls) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
  for (const [key, value] of Object.entries({x,y,width,height,class:cls})) node.setAttribute(key, value);
  svg.append(node);
}
function setView(svg, width, height) {
  svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
  svg.replaceChildren();
}
function renderPlan(event) {
  event?.preventDefault();
  currentPlan = null;
  usePlan.disabled = true;
  planCanvas.replaceChildren();
  try {
    const values = fields.map(id => Number(el(id).value));
    if (fields.some(id => el(id).value.trim() === '') || values.some(value => !Number.isSafeInteger(value))) throw Error('请输入整数尺寸与重叠量');
    const [image_width,image_height,tile_width,tile_height,overlap_x,overlap_y] = values;
    const plan = JSON.parse(moontile_plan(JSON.stringify({image_width,image_height,tile_width,tile_height,overlap_x,overlap_y})));
    if (plan.error) throw Error(plan.error);
    setView(planCanvas, plan.image_width, plan.image_height);
    const displayed = plan.tiles.slice(0, 1000);
    for (const tile of displayed) {
      rect(planCanvas, tile.x, tile.y, tile.width, tile.height, 'tile');
      if (plan.tiles.length <= 100) {
        const label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
        const size = Math.min(tile.width, tile.height) * .08;
        label.setAttribute('x', tile.x + size * .3); label.setAttribute('y', tile.y + size * 1.2);
        label.setAttribute('font-size', size); label.setAttribute('class', 'tile-label');
        label.textContent = String(tile.id); planCanvas.append(label);
      }
    }
    planStatus.textContent = `已生成 ${plan.tiles.length} 个切片` + (plan.tiles.length > 1000 ? '；图中显示前 1000 个。' : '。');
    currentPlan = plan;
    usePlan.disabled = false;
  } catch (error) {
    planStatus.textContent = `规划失败：${error.message}`;
  }
}
function renderMerge() {
  canvas.replaceChildren();
  mergeStatus.textContent = '';
  try {
    const src = JSON.parse(input.value), out = JSON.parse(moontile_process(input.value));
    if (out.error) throw Error(out.error);
    setView(canvas, src.image_width, src.image_height);
    for (const {tile:t} of src.tiles.slice(0, 1000)) rect(canvas, t.x, t.y, t.width, t.height, 'tile');
    if (src.tiles.length > 1000) mergeStatus.textContent = '图中显示前 1000 个切片；结果包含全部输入。';
    const suppressed = new Set(out.suppressed.map(item => item.suppressed_id));
    for (const d of out.restored) { const b=d.box; rect(canvas,b.x1,b.y1,b.x2-b.x1,b.y2-b.y1,suppressed.has(d.id)?'suppressed':'source'); }
    for (const d of out.kept) { const b=d.box; rect(canvas,b.x1,b.y1,b.x2-b.x1,b.y2-b.y1,'kept'); }
    report.textContent = JSON.stringify(out, null, 2);
  } catch (error) { report.textContent = `处理失败：${error.message}`; }
}
el('plan-form').addEventListener('submit', renderPlan);
for (const id of fields) el(id).addEventListener('input', () => {
  currentPlan = null; usePlan.disabled = true; planCanvas.replaceChildren();
  planStatus.textContent = '参数已修改，请重新生成规划。';
});
usePlan.addEventListener('click', () => {
  if (!currentPlan) return;
  input.value = JSON.stringify({image_width:currentPlan.image_width,image_height:currentPlan.image_height,threshold:.5,metric:'iou',class_agnostic:false,tiles:currentPlan.tiles.map(tile => ({tile,detections:[]}))}, null, 2);
  renderMerge();
});
el('run').addEventListener('click', renderMerge);
renderPlan();
renderMerge();
