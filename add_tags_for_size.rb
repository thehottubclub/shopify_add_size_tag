require 'json'
require 'httparty'
require 'pry'
require 'shopify_api'
require 'yaml'

@outcomes = {
  errors: [],
  skipped: [],
  saved_tags: [],
  unable_to_save_tags: [],
  unable_to_find_new_tags: [],
  skipped_because_tags_didnt_match: [],
  skipped_because_product_has_no_estimate_size_metafield: [],
  responses: []
}

#Load secrets from yaml file & set values to use
data = YAML::load(File.open('config/secrets.yml'))
SECURE_URL_BASE = data['url_base']
API_DOMAIN = data['api_dpmain']

#Constants
DIVIDER = '------------------------------------------'
DELAY_BETWEEN_REQUESTS = 0.11
NET_INTERFACE = HTTParty
STARTPAGE = 2
ENDPAGE = 3
METAFIELDS_TO_TAGS_HASH = {
  ['OSFA', 'OS', 'One Size', 'All Sizes', 'all sizes', 'XS-XXL'] => ['XS', 'S', 'M', 'L', 'XL', 'XXL'],
  ['OSFM', 'S-L'] => ['S', 'M', 'L'],
  ['Most Sizes', 'S-XL'] => ['S', 'M', 'L', 'XL'],
  ['XXXS', '3XS'] => ['XXXS'],
  ['XXS', '2XS'] => ['XXS'],
  ['XXS/XS', '2XS/XS', 'XXS-XS', '2XS-XS'] => ['XXS', 'XS'],
  ['XS', 'Extra Small'] => ['XS'],
  ['XS/S', 'XS-S'] => ['XS', 'S'],
  ['XS-M'] => ['XS', 'S', 'M'],
  ['XS-L'] => ['XS', 'S', 'M', 'L'],
  ['XS-XL'] => ['XS', 'S', 'M', 'L', 'XL'],
  ['S', 'Small'] => ['S'],
  ['S/M', 'S-M'] => ['S', 'M'],
  ['S-XXL'] => ['S', 'M', 'L', 'XL', 'XXL'],
  ['M', 'Medium'] => ['M'],
  ['M/L', 'M-L'] => ['M', 'L'],
  ['M-XL'] => ['M', 'L', 'XL'],
  ['M-XXL'] => ['M', 'L', 'XL', 'XXL'],
  ['L', 'Large'] => ['L'],
  ['L/XL', 'L-XL'] => ['L', 'XL'],
  ['L-XXL'] => ['L', 'XL', 'XXL'],
  ['XL', 'Extra Large'] => ['XL'],
  ['XL/XXL', 'XL/2XL', 'XL-XXL', 'XL-2XL'] => ['XL', 'XXL'],
  ['XXL', '2XL'] => ['XXL'],
  ['XXL/XXXL', 'XXL/3XL', '2XL/3XL', 'XXL-XXXL', 'XXL-3XL', '2XL-3XL'] => ['XXL', '3XL'],
  ['XXXL', '3XL'] => ['3XL']
}

def main
  puts "starting at #{Time.now}"

  if ARGV[0] =~ /product_id=/
    do_product_by_id(ARGV[0].scan(/product_id=(\d+)/).first.first)
  elsif ARGV[0] =~ /\d+/ && ARGV[1] =~ /\d+/
    startpage = ARGV[0].to_i
    endpage = ARGV[1].to_i
    do_page_range(startpage, endpage)
  else
    do_page_range(STARTPAGE, ENDPAGE)
  end

  puts "finished at #{Time.now}"

  File.open(filename, 'w') do |file|
    file.write @outcomes.to_json
  end

  @outcomes.each_pair do |k,v|
    puts "#{k}: #{v.size}"
  end
end

def filename
  "data/add_tags_for_size_#{Time.now.strftime("%Y-%m-%d_%k%M%S")}.json"
end

def do_page_range(startpage, endpage)
  (startpage .. endpage).to_a.each do |current_page|
    do_page(current_page)
  end
end

def do_page(page_number)
  puts "Starting page #{page_number}"

  products = get_products(page_number)

  # counter = 0
  products.each do |product|
    @product_id = product['id']
    do_product(product)
    # counter += 1
    # return "done" if counter == LIMIT
  end

  puts "Finished page #{page_number}"
end

def get_products(page_number)
  response = secure_get("/products.json?page=#{page_number}")

  JSON.parse(response.body)['products']
end

def get_product(id)
  JSON.parse( secure_get("/products/#{id}.json").body )['product']
end

def do_product_by_id(id)
  do_product(get_product(id))
end

def do_product(product)
  begin
    puts DIVIDER
    old_tags = product['tags'].split(', ')

    if( should_skip_based_on?(old_tags) )
      skip(product)
    else
      add_size_tags(product)
    end
  rescue Exception => e
    @outcomes[:errors].push @product_id
    puts "error on product #{product['id']}: #{e.message}"
    puts e.backtrace.join("\n")
    raise e
  end
end

def skip(product)
  @outcomes[:skipped].push @product_id
  puts "Skipping product #{product['id']}"
end

def secure_get(relative_url)
  sleep DELAY_BETWEEN_REQUESTS
  url = SECURE_URL_BASE + relative_url
  result = NET_INTERFACE.get(url)
end

def secure_put(relative_url, params)
  sleep DELAY_BETWEEN_REQUESTS

  url = SECURE_URL_BASE + relative_url

  result = NET_INTERFACE.put(url, body: params)

  @outcomes[:responses].push({
    method: 'put', requested_url: url, body: result.body, code: result.code
  })
end

def put(url, params)
  NET_INTERFACE.put(url, query: params)
end

def add_size_tags(product)
  metafields = metafields_for_product(product)

  if new_tags = new_tags_for(metafields, product['tags'].split(', '))
    if result = save_tags(product, new_tags)
      @outcomes[:saved_tags].push @product_id
      puts "Saved tags for #{product['id']}: #{new_tags}"
    else
      @outcomes[:unable_to_save_tags].push @product_id
      puts "Unable to save tags for #{product['id']}:  #{result.body}"
    end
  else
    @outcomes[:unable_to_find_new_tags].push @product_id
    puts "unable find new tags_for product #{product['id']}"
  end
end

def save_tags(product, new_tags)
  secure_put(
    "/products/#{product['id']}.json",
    {product: {id: product['id'], tags: new_tags}}
  )
end

def metafields_for_product(product)
  secure_get("/products/#{product['id']}/metafields.json")
end


def should_skip_based_on?(old_tags)
  tags_that_indicate_skip = METAFIELDS_TO_TAGS_HASH.values.flatten.uniq

  tags_that_indicate_skip.each do |skip_tag|
    if old_tags.include?(skip_tag)
      return true
    end
  end

  false
end

def new_tags_for(metafields, old_tags)
  if estimated_size = get_metafield(metafields, 'item-estimatedsize')
    if tags_to_add = get_tags_to_add(estimated_size.strip)
      add_tags(old_tags, tags_to_add)
    else
      @outcomes[:skipped_because_tags_didnt_match].push @product_id
      puts "skipping because tags didn't match: #{old_tags}; #{estimated_size}"
    end
  else
    @outcomes[:skipped_because_product_has_no_estimate_size_metafield].push @product_id
    puts "skipping because product has no estimated_size metafield"
  end
end

def get_metafield(metafields, field_name)
  metafields['metafields'].each do |field|
    if field['key'] == field_name
      return field['value']
    end
  end

  return false
end

def get_tags_to_add(estimated_size)
  METAFIELDS_TO_TAGS_HASH.each_pair do |key, value|
    if(key.include?(estimated_size))
      return value
    end
  end

  false
end

def add_tags(old_tags, tags_to_add)
  old_tags.concat(tags_to_add)
end

def get_metadata(product)
  puts product.inspect

  raise "done"
end

main
